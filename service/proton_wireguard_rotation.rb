require_relative 'opnsense'
require_relative 'proton_wireguard'

module Service
  # Safely rotates an existing OPNsense WireGuard instance and peer.
  class ProtonWireguardRotation # rubocop:disable Metrics/ClassLength
    LOCK_PATH = File.expand_path('../data/wireguard-import.lock', __dir__)
    INSTANCE_FIELDS = %w[pubkey privkey tunneladdress].freeze
    PEER_FIELDS = %w[name pubkey tunneladdress serveraddress serverport].freeze
    ADDRESS_FAMILY_NAMES = { 4 => 'IPv4', 6 => 'IPv6' }.freeze

    class Error < StandardError; end
    class Busy < Error; end

    def initialize(config, opnsense: Service::Opnsense.new(config), lock_path: LOCK_PATH)
      @opnsense = opnsense
      @lock_path = lock_path
    end

    def validate_request(instance_uuid:, peer_uuid:)
      @opnsense.validate_wireguard_config
      {
        instance_uuid: validate_uuid(instance_uuid, 'Instance'),
        peer_uuid: validate_uuid(peer_uuid, 'Peer')
      }
    rescue Service::Opnsense::WireguardImportError => e
      raise Error, e.message
    end

    def rotate(wireguard, instance_uuid:, peer_uuid:, rename_peer: false)
      peer_name = requested_peer_name(wireguard, rename_peer)
      selection = validate_request(instance_uuid: instance_uuid, peer_uuid: peer_uuid)
      with_lock { perform_rotation(wireguard, peer_name: peer_name, **selection) }
    end

    private

    def perform_rotation(wireguard, instance_uuid:, peer_uuid:, peer_name:) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      state = { instance_uuid: instance_uuid, peer_uuid: peer_uuid }
      completed = false
      rollback_attempted = false

      begin
        prepare_rotation(state)
        prepare_address_policy(state, wireguard)
        set_instance_enabled(state, false)
        @opnsense.reconfigure_wireguard
        verify_instance_stopped(state)
        update_peer(state, wireguard.fetch(:peer), peer_name)
        update_instance(state, wireguard.fetch(:instance))
        @opnsense.reconfigure_wireguard
        set_instance_enabled(state, true)
        @opnsense.reconfigure_wireguard
        verify_instance_active(
          state,
          instance_public_key: wireguard.fetch(:instance).fetch(:public_key),
          peer_public_key: wireguard.fetch(:peer).fetch(:public_key),
          state_label: 'imported'
        )
        completed = true

        { instance_name: state[:instance_name], peer_name: peer_name || state[:peer_name] }
      rescue StandardError => e
        rollback_required = rotation_changed?(state)
        rollback_attempted = true
        raise rotation_error(e, rollback_required, rollback(state))
      ensure
        # Thread termination still runs ensure; restore state if an in-process worker is stopped.
        rollback(state) unless completed || rollback_attempted
      end
    end

    def prepare_rotation(state) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      instance = @opnsense.wireguard_instance(state[:instance_uuid])
      peer = @opnsense.wireguard_peer(state[:peer_uuid])
      state[:instance_name] = instance['name'].to_s
      state[:peer_name] = peer['name'].to_s
      state[:interface] = instance['interface'].to_s
      if state[:interface].empty?
        raise Error, "OPNsense did not return the interface for instance #{state[:instance_name]}"
      end

      state[:original_enabled] = instance_enabled?(instance['enabled'])
      raise Error, "Instance #{state[:instance_name]} must be enabled before import" unless state[:original_enabled]

      state[:current_enabled] = state[:original_enabled]
      peer_instances = selected_values(peer['servers'])
      unless peer_instances.include?(state[:instance_uuid])
        raise Error, "Peer #{state[:peer_name]} is not assigned to instance #{state[:instance_name]}"
      end

      state[:original_instance] = normalized_fields(instance, INSTANCE_FIELDS)
      state[:original_peer] = normalized_fields(peer, PEER_FIELDS).merge('servers' => peer_instances.join(','))
    end

    def prepare_address_policy(state, wireguard)
      state[:instance_tunnel_addresses] = addresses_for_existing_families(
        wireguard.fetch(:instance).fetch(:tunnel_addresses),
        state.fetch(:original_instance).fetch('tunneladdress'),
        'instance tunnel addresses'
      )
      state[:peer_allowed_ips] = addresses_for_existing_families(
        wireguard.fetch(:peer).fetch(:allowed_ips),
        state.fetch(:original_peer).fetch('tunneladdress'),
        'peer allowed IPs'
      )
    end

    # Mark writes before sending them because OPNsense may save a request whose response is lost.
    def update_peer(state, peer, peer_name)
      state[:peer_updated] = true
      payload = {
        'pubkey' => peer.fetch(:public_key),
        'tunneladdress' => opnsense_list(state.fetch(:peer_allowed_ips)),
        'serveraddress' => peer.fetch(:endpoint_address),
        'serverport' => peer.fetch(:endpoint_port).to_s,
        'servers' => state.fetch(:original_peer).fetch('servers')
      }
      payload['name'] = peer_name if peer_name
      @opnsense.save_wireguard_peer(state[:peer_uuid], payload)
    end

    def requested_peer_name(wireguard, rename_peer)
      return unless rename_peer

      metadata = wireguard.fetch(:metadata, {})
      Service::ProtonWireguard.peer_name_for(metadata[:proton_server_identifier])
    rescue Service::ProtonWireguard::ImportError => e
      raise Error, e.message
    end

    def update_instance(state, instance)
      state[:instance_updated] = true
      payload = {
        'pubkey' => instance.fetch(:public_key),
        'privkey' => instance.fetch(:private_key),
        'tunneladdress' => opnsense_list(state.fetch(:instance_tunnel_addresses))
      }
      @opnsense.save_wireguard_instance(state[:instance_uuid], payload)
    end

    def addresses_for_existing_families(imported_value, existing_value, subject)
      imported = addresses_with_families(imported_value, "Proton #{subject}")
      required_families = addresses_with_families(
        existing_value, "adopted OPNsense #{subject}"
      ).map(&:last).uniq
      validate_required_families(imported, required_families, subject)

      imported.select { |_address, family| required_families.include?(family) }.map(&:first).join(', ')
    end

    def validate_required_families(imported, required_families, subject)
      missing_families = required_families - imported.map(&:last)
      return if missing_families.empty?

      missing = missing_families.map { |family| ADDRESS_FAMILY_NAMES.fetch(family) }.join(' and ')
      raise Error, "Proton configuration is missing #{missing} required by the adopted OPNsense #{subject}"
    end

    def addresses_with_families(value, subject)
      addresses = value.to_s.split(',').map(&:strip).reject(&:empty?)
      raise Error, "#{subject} did not contain any addresses" if addresses.empty?

      addresses.map do |address|
        [address, IPAddr.new(address).ipv4? ? 4 : 6]
      end
    rescue IPAddr::InvalidAddressError
      raise Error, "#{subject} contains an invalid address"
    end

    def set_instance_enabled(state, enabled)
      state[:current_enabled] = enabled
      @opnsense.save_wireguard_instance(state[:instance_uuid], 'enabled' => enabled ? '1' : '0')
    end

    def rollback(state)
      return [] unless rotation_changed?(state)

      errors = []
      return errors if objects_changed?(state) &&
                       state[:current_enabled] &&
                       !disable_for_rollback(state, errors)

      restore_configuration(state, errors)
      restore_enabled_state(state, errors)
      rollback_action(errors, 'original enabled state apply') { @opnsense.reconfigure_wireguard }
      verify_restored_runtime(state, errors)
      errors
    end

    def restore_configuration(state, errors)
      return unless objects_changed?(state)

      restore_peer(state, errors) if state[:peer_updated]
      restore_instance(state, errors) if state[:instance_updated]
      rollback_action(errors, 'restored configuration apply') { @opnsense.reconfigure_wireguard }
    end

    def restore_enabled_state(state, errors)
      return if state[:current_enabled] == state[:original_enabled]

      rollback_action(errors, 'original enabled state restore') do
        set_instance_enabled(state, state[:original_enabled])
      end
    end

    def rotation_changed?(state)
      objects_changed?(state) ||
        (state.key?(:current_enabled) && state[:current_enabled] != state[:original_enabled])
    end

    def objects_changed?(state)
      state[:peer_updated] || state[:instance_updated]
    end

    def disable_for_rollback(state, errors)
      rollback_action(errors, 'instance disable') { set_instance_enabled(state, false) }
      rollback_action(errors, 'disabled state apply') { @opnsense.reconfigure_wireguard }
      rollback_action(errors, 'disabled state verification') { verify_instance_stopped(state) }
    end

    def restore_peer(state, errors)
      rollback_action(errors, 'peer restore') do
        @opnsense.save_wireguard_peer(state[:peer_uuid], state[:original_peer])
      end
    end

    def restore_instance(state, errors)
      rollback_action(errors, 'instance restore') do
        @opnsense.save_wireguard_instance(state[:instance_uuid], state[:original_instance])
      end
    end

    def rollback_action(errors, label)
      yield
      true
    rescue StandardError => e
      errors << "#{label} failed (#{e.message})"
      false
    end

    def verify_instance_stopped(state)
      active = @opnsense.wireguard_runtime.any? { |record| record['if'].to_s == state[:interface] }
      return unless active

      raise Error, "OPNsense WireGuard instance #{state[:instance_name]} is still active after disable/apply"
    end

    def verify_instance_active(state, instance_public_key:, peer_public_key:, state_label:)
      records = @opnsense.wireguard_runtime.select { |record| record['if'].to_s == state[:interface] }
      instance_active = runtime_key_present?(records, 'interface', instance_public_key)
      peer_active = runtime_key_present?(records, 'peer', peer_public_key)
      return if instance_active && peer_active

      raise Error, "OPNsense WireGuard instance #{state[:instance_name]} is not active with the #{state_label} keys"
    end

    def runtime_key_present?(records, type, public_key)
      records.any? { |record| record['type'] == type && record['public-key'].to_s == public_key }
    end

    def verify_restored_runtime(state, errors)
      rollback_action(errors, 'original runtime state verification') do
        verify_instance_active(
          state,
          instance_public_key: state.fetch(:original_instance).fetch('pubkey'),
          peer_public_key: state.fetch(:original_peer).fetch('pubkey'),
          state_label: 'restored'
        )
      end
    end

    def rotation_error(error, rollback_required, rollback_errors)
      message = if error.is_a?(Error) || error.is_a?(Service::Opnsense::WireguardImportError)
                  error.message
                else
                  "OPNsense WireGuard rotation failed: #{error.message}"
                end
      Error.new("#{message}#{rollback_status(rollback_required, rollback_errors)}")
    end

    def rollback_status(rollback_required, rollback_errors)
      return "; rollback incomplete: #{rollback_errors.join('; ')}" if rollback_errors.any?
      return '; rollback completed' if rollback_required

      ''
    end

    def with_lock
      File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        acquired = lock.flock(File::LOCK_EX | File::LOCK_NB)
        raise Busy, 'another OPNsense WireGuard rotation is already in progress' unless acquired

        yield
      end
    rescue SystemCallError => e
      raise Error, "could not secure the OPNsense WireGuard rotation lock: #{e.message}"
    end

    def validate_uuid(uuid, label)
      value = uuid.to_s
      return value.downcase if value.match?(Service::Opnsense::OPN_UUID)

      raise Error, "#{label} selection is invalid"
    end

    def normalized_fields(record, fields)
      fields.to_h do |field|
        value = record[field]
        [field, value.is_a?(Hash) ? selected_values(value).join(',') : value.to_s]
      end
    end

    def selected_values(value)
      return value.to_s.split(',').map(&:strip).reject(&:empty?) unless value.is_a?(Hash)

      value.filter_map do |key, details|
        key if details.is_a?(Hash) && details['selected'].to_i == 1
      end
    end

    def instance_enabled?(value)
      %w[1 true checked on enabled].include?(value.to_s.downcase)
    end

    def opnsense_list(value)
      value.to_s.split(',').map(&:strip).reject(&:empty?).join(',')
    end
  end
end
