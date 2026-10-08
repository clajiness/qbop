require 'forwardable'
require_relative 'settings'
require_relative 'helpers'

module Service
  # Descriptions and controls for the browser editor; resolution and validation remain in Settings.
  class SettingsPresentation
    GROUPS = {
      'Application' => {
        ui_mode: 'Color theme for the browser interface.',
        loop_freq: 'Seconds between forwarded-port checks.',
        required_attempts: 'Consecutive mismatches before qbop updates a downstream integration.',
        port_source: 'Selects where qbop obtains the forwarded port.'
      },
      'ProtonVPN' => {
        proton_gateway: 'VPN gateway used for ProtonVPN NAT-PMP port requests.'
      },
      'Gluetun' => {
        gluetun_addr: 'Base URL for the Gluetun control API. Reverse-proxy path prefixes are supported.',
        gluetun_api_key: 'Control API key. Takes precedence over Basic authentication.',
        gluetun_user: 'Basic authentication username, used when no API key is configured.',
        gluetun_pass: 'Basic authentication password. Configure both username and password.',
        gluetun_ssl_verify: 'Verify the Gluetun control API TLS certificate.'
      },
      'OPNsense' => {
        opnsense_skip: 'Skip OPNsense port synchronization and WireGuard import.',
        opnsense_interface_addr: 'Root HTTP(S) URL for the OPNsense API, without a path prefix.',
        opnsense_api_key: 'OPNsense API key.',
        opnsense_api_secret: 'OPNsense API secret.',
        opnsense_alias_name: 'OPNsense firewall alias synchronized with the forwarded port.',
        opnsense_ssl_verify: 'Verify the OPNsense API TLS certificate.'
      },
      'qBittorrent' => {
        qbit_skip: 'Skip qBittorrent port synchronization.',
        qbit_addr: 'Root HTTP(S) URL for the qBittorrent Web API, without a path prefix.',
        qbit_api_key: 'Bearer API key. Takes precedence over username/password login.',
        qbit_user: 'Login username, used when no API key is configured.',
        qbit_pass: 'Login password, used when no API key is configured.',
        qbit_ssl_verify: 'Verify the qBittorrent Web API TLS certificate.'
      },
      'Logging' => {
        log_lines: 'Default number of lines shown in the log viewer.',
        log_reverse: 'Show newest log entries first by default.',
        log_to_stdout: 'Send synchronization job logs to stdout instead of the log file.'
      }
    }.transform_values(&:freeze).freeze
    DYNAMIC_KEYS = %i[ui_mode log_lines log_reverse].freeze
    private_constant :GROUPS, :DYNAMIC_KEYS

    Entry = Data.define(:metadata, :description, :restart_required) do
      extend Forwardable
      def_delegators :metadata, :key, :label, :value, :source, :environment_name, :environment_override?,
                     :secret?, :database_value_present?, :default?, :unset?, :default_value,
                     :choices, :minimum, :maximum

      def restart_required? = restart_required

      def invalid_port_source?
        key == :port_source && !choices.include?(input_value)
      end

      def input_type
        { enum: 'select', boolean: 'select', integer: 'number', url: 'url', text: 'text', secret: 'password' }
          .fetch(metadata.input_type)
      end

      def input_choices
        metadata.input_type == :boolean ? %w[true false] : choices
      end

      def input_value
        return if secret?

        metadata.input_type == :boolean ? (value.to_s.downcase == 'true').to_s : display_value
      end

      def display_value
        return '' if secret? || value.nil?
        return value.to_s unless metadata.input_type == :url && !value.to_s.strip.empty?

        Helpers.new.redact_url_credentials(value)
      end

      def source_label
        return 'Environment' if environment_override?
        return 'Configured in qbop' if source == :database

        unset? ? 'Not configured' : 'Default'
      end
    end

    def initialize(settings: Settings.new)
      @settings = settings
    end

    def sections
      metadata = @settings.all_metadata
      GROUPS.transform_values do |entries|
        entries.map { |key, description| build_entry(metadata.fetch(key), description) }
      end
    end

    def find(name)
      key = Settings.keys.find { |candidate| candidate.to_s == name }
      return unless key

      description = GROUPS.values.find { |entries| entries.key?(key) }.fetch(key)
      build_entry(@settings.metadata(key), description)
    end

    private

    def build_entry(metadata, description)
      Entry.new(metadata: metadata, description: description,
                restart_required: !DYNAMIC_KEYS.include?(metadata.key))
    end
  end
end
