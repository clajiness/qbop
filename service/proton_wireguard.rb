require 'base64'
require 'ipaddr'

module Service
  # Parses ProtonVPN WireGuard configurations into OPNsense instance and peer settings.
  class ProtonWireguard # rubocop:disable Metrics/ClassLength
    MAX_CONFIG_BYTES = 16_384
    PROTON_SERVER_IDENTIFIER = /\A[A-Za-z0-9-]+#[0-9]+\z/
    OPNSENSE_PEER_NAME = /\A[0-9A-Za-z._-]{1,64}\z/

    # Common wg-quick settings are accepted even when their existing OPNsense values are preserved.
    SUPPORTED_SETTINGS = {
      'Interface' => %w[PrivateKey Address DNS ListenPort MTU],
      'Peer' => %w[PublicKey AllowedIPs Endpoint PersistentKeepalive]
    }.freeze
    REQUIRED_SETTINGS = {
      'Interface' => %w[PrivateKey Address DNS],
      'Peer' => %w[PublicKey AllowedIPs Endpoint]
    }.freeze

    class ImportError < StandardError; end

    def self.peer_name_for(server_identifier)
      identifier = server_identifier.to_s
      error = 'Unable to rename peer because a Proton server identifier was not found in the configuration.'
      raise ImportError, error unless identifier.match?(PROTON_SERVER_IDENTIFIER)

      prefix, _separator, number = identifier.rpartition('#')
      peer_name = "Proton_#{prefix}#{number}"
      error = 'Unable to rename peer because the generated name is not valid for OPNsense.'
      raise ImportError, error unless peer_name.match?(OPNSENSE_PEER_NAME)

      peer_name
    end

    def initialize(helpers = Service::Helpers.new)
      @helpers = helpers
    end

    def import(config_text)
      config = validate_config_text(config_text)
      sections, metadata = parse(config)
      validate_required_settings(sections)
      validate_port_forwarding(metadata)

      build_import(sections, metadata)
    end

    private

    def validate_config_text(config_text)
      config = config_text.to_s.dup.force_encoding(Encoding::UTF_8)
      raise ImportError, 'configuration must be valid UTF-8 text' unless config.valid_encoding?
      raise ImportError, 'paste or upload a ProtonVPN WireGuard configuration' if config.strip.empty?
      raise ImportError, "configuration exceeds #{MAX_CONFIG_BYTES} bytes" if config.bytesize > MAX_CONFIG_BYTES

      config
    end

    def parse(config) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      sections = SUPPORTED_SETTINGS.keys.to_h { |section| [section, {}] }
      metadata = {}
      current_section = nil
      seen_sections = Hash.new(0)

      config.each_line.with_index(1) do |line, line_number|
        content = line.strip
        next if content.empty?

        if content.start_with?('#')
          parse_metadata(content, metadata)
          parse_server_identifier(content, metadata, current_section, sections)
        elsif (section = content[/\A\[([^\]]+)\]\z/, 1])
          current_section = select_section(section, seen_sections)
        else
          parse_setting(content, line_number, current_section, sections)
        end
      end

      [sections, metadata]
    end

    def parse_metadata(content, metadata)
      comment = content.delete_prefix('#').strip
      if (match = comment.match(/\ANAT-PMP\s*\(Port Forwarding\)\s*=\s*(.+)\z/i))
        metadata[:nat_pmp] = match[1].strip.downcase
      elsif (match = comment.match(/\AModerate NAT\s*=\s*(.+)\z/i))
        metadata[:moderate_nat] = match[1].strip.downcase
      end
    end

    def parse_server_identifier(content, metadata, current_section, sections)
      return unless current_section == 'Peer' && sections.fetch('Peer').empty?

      comment = content.delete_prefix('#').strip
      metadata[:proton_server_identifier] ||= comment if comment.match?(PROTON_SERVER_IDENTIFIER)
    end

    def select_section(section, seen_sections)
      raise ImportError, "unsupported WireGuard section [#{section}]" unless SUPPORTED_SETTINGS.key?(section)

      seen_sections[section] += 1
      raise ImportError, "configuration must contain exactly one [#{section}] section" if seen_sections[section] > 1

      section
    end

    def parse_setting(content, line_number, current_section, sections) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      raise ImportError, "setting found before a section on line #{line_number}" unless current_section

      key, value = content.split('=', 2)&.map(&:strip)
      unless key && value && !key.empty? && !value.empty?
        raise ImportError, "invalid WireGuard setting on line #{line_number}"
      end
      unless SUPPORTED_SETTINGS.fetch(current_section).include?(key)
        raise ImportError, "unsupported #{current_section} setting #{key}"
      end
      raise ImportError, "duplicate #{current_section} setting #{key}" if sections[current_section].key?(key)

      sections[current_section][key] = value
    end

    def validate_required_settings(sections)
      REQUIRED_SETTINGS.each do |section, settings|
        settings.each do |setting|
          next if sections.fetch(section).key?(setting)

          raise ImportError, "missing #{setting} in [#{section}]"
        end
      end
    end

    def validate_port_forwarding(metadata)
      if metadata[:moderate_nat] && metadata[:moderate_nat] != 'off'
        raise ImportError, 'Moderate NAT is incompatible with ProtonVPN port forwarding'
      end
      return if metadata[:nat_pmp] == 'on'

      raise ImportError, 'NAT-PMP (Port Forwarding) must be enabled in the ProtonVPN configuration'
    end

    def build_import(sections, metadata) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      interface = sections.fetch('Interface')
      peer = sections.fetch('Peer')

      private_key = validate_key(interface.fetch('PrivateKey'), 'Interface private key')
      peer_public_key = validate_key(peer.fetch('PublicKey'), 'Peer public key')
      public_key = derive_public_key(private_key)
      addresses = validate_network_list(interface.fetch('Address'), 'Interface address')
      dns_servers = validate_ip_list(interface.fetch('DNS'), 'DNS server')
      allowed_ips = validate_network_list(peer.fetch('AllowedIPs'), 'Peer allowed IPs')
      endpoint_address, endpoint_port = validate_endpoint(peer.fetch('Endpoint'))

      {
        instance: {
          public_key: public_key,
          private_key: private_key,
          dns_servers: dns_servers.join(', '),
          tunnel_addresses: addresses.join(', '),
          gateway: dns_servers.first
        },
        peer: {
          public_key: peer_public_key,
          allowed_ips: allowed_ips.join(', '),
          endpoint_address: endpoint_address,
          endpoint_port: endpoint_port
        },
        metadata: metadata.slice(:proton_server_identifier)
      }
    end

    def validate_key(value, label)
      decoded = Base64.strict_decode64(value)
      valid = decoded.bytesize == 32 && Base64.strict_encode64(decoded) == value
      raise ImportError, "#{label} is not a valid WireGuard key" unless valid

      value
    rescue ArgumentError, TypeError
      raise ImportError, "#{label} is not a valid WireGuard key"
    end

    def derive_public_key(private_key)
      public_key = @helpers.generate_wg_public_key(private_key)
      validate_key(public_key, 'Derived public key')
    rescue ImportError
      raise ImportError, 'could not derive a public key from the Interface private key'
    end

    def validate_network_list(value, label)
      validate_list(value, label) do |item|
        item.include?('/') && valid_ip_network?(item)
      end
    end

    def validate_ip_list(value, label)
      validate_list(value, label) do |item|
        !item.include?('/') && valid_ip_network?(item)
      end
    end

    def validate_list(value, label, &validator)
      items = value.split(',').map(&:strip)
      raise ImportError, "#{label} is invalid" if items.empty? || items.any?(&:empty?)
      raise ImportError, "#{label} is invalid" unless items.all?(&validator)

      items
    end

    def valid_ip_network?(value)
      IPAddr.new(value)
      true
    rescue IPAddr::InvalidAddressError
      false
    end

    def validate_endpoint(value)
      match = value.match(/\A\[([^\]]+)\]:(\d+)\z/) || value.match(/\A([^:]+):(\d+)\z/)
      raise ImportError, 'Peer endpoint must include an address and port' unless match

      address = match[1]
      port = validate_port(match[2])
      raise ImportError, 'Peer endpoint address is invalid' unless valid_endpoint_address?(address)

      [address, port]
    end

    def valid_endpoint_address?(address)
      return true if valid_ip_network?(address)

      hostname = address.delete_suffix('.')
      return false if hostname.empty? || hostname.length > 253

      hostname.split('.').all? do |label|
        label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i)
      end
    end

    def validate_port(value)
      string = value.to_s
      raise ImportError, 'Endpoint port is invalid' unless string.match?(/\A\d+\z/)

      port = string.to_i
      raise ImportError, 'Endpoint port is invalid' unless port.between?(1, 65_535)

      port
    end
  end
end
