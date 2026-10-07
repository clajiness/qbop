require_relative 'settings_validation'
require_relative 'settings_encryption'
require_relative 'settings_resolution'

module Service
  # Resolves supported settings once per instance; only set/delete change stored overrides.
  class Settings # rubocop:disable Metrics/ClassLength
    ValidationError = SettingsValidation::ValidationError
    ConfigurationError = SettingsEncryption::ConfigurationError
    Resolution = SettingsResolution

    DEFINITIONS = {
      loop_freq: { environment: %w[LOOP_FREQ], name: 'loop_freq', default: 45, blank_is_absent: true,
                   read: :loop_frequency, write: :integer },
      required_attempts: { environment: %w[REQUIRED_ATTEMPTS], name: 'required_attempts', default: 3,
                           blank_is_absent: true, read: :required_attempts, write: :integer, range: 1..10 },
      port_source: { environment: %w[PORT_SOURCE], name: 'port_source', default: 'proton', blank_is_absent: false,
                     write: :enum, allowed: %w[proton gluetun] },
      proton_gateway: { environment: %w[PROTON_GATEWAY], name: 'proton_gateway', default: '10.2.0.1',
                        blank_is_absent: true, write: :text },
      ui_mode: { environment: %w[UI_MODE], name: 'ui_mode', default: 'dark', blank_is_absent: true,
                 preserve_blank: true, read: :downcase, write: :enum, allowed: %w[dark light], case_insensitive: true },
      log_lines: { environment: %w[LOG_LINES], name: 'log_lines', default: 50, blank_is_absent: true,
                   preserve_blank: true, write: :integer, range: 1..5000 },
      log_reverse: { environment: %w[LOG_REVERSE], name: 'log_reverse', default: 'false', blank_is_absent: true,
                     preserve_blank: true, write: :boolean },
      log_to_stdout: { environment: %w[LOG_TO_STDOUT], name: 'log_to_stdout', default: 'false', blank_is_absent: true,
                       preserve_blank: true, write: :boolean },
      gluetun_addr: { environment: %w[GLUETUN_ADDR], name: 'gluetun_addr', default: 'http://gluetun:8000',
                      blank_is_absent: true, write: :url },
      gluetun_ssl_verify: { environment: %w[GLUETUN_SSL_VERIFY], name: 'gluetun_ssl_verify', default: false,
                            blank_is_absent: true, read: :boolean, write: :boolean },
      opnsense_skip: { environment: %w[OPN_SKIP], name: 'opnsense_skip', default: 'false', blank_is_absent: true,
                       preserve_blank: true, write: :boolean },
      opnsense_interface_addr: { environment: %w[OPN_INTERFACE_ADDR], name: 'opnsense_interface_addr', default: nil,
                                 blank_is_absent: true, preserve_blank: true, write: :url, root_url: true },
      opnsense_alias_name: { environment: %w[OPN_ALIAS_NAME OPN_PROTON_ALIAS_NAME], name: 'opnsense_alias_name',
                             default: nil, blank_is_absent: true, write: :text },
      opnsense_ssl_verify: { environment: %w[OPN_SSL_VERIFY], name: 'opnsense_ssl_verify', default: false,
                             blank_is_absent: true, read: :boolean, write: :boolean },
      qbit_skip: { environment: %w[QBIT_SKIP], name: 'qbit_skip', default: 'false', blank_is_absent: true,
                   preserve_blank: true, write: :boolean },
      qbit_addr: { environment: %w[QBIT_ADDR], name: 'qbit_addr', default: nil, blank_is_absent: true,
                   preserve_blank: true, write: :url, root_url: true },
      qbit_ssl_verify: { environment: %w[QBIT_SSL_VERIFY], name: 'qbit_ssl_verify', default: false,
                         blank_is_absent: true, read: :boolean, write: :boolean },
      gluetun_api_key: { environment: %w[GLUETUN_API_KEY], name: 'gluetun_api_key', default: nil,
                         blank_is_absent: true, write: :secret, secret: true },
      gluetun_user: { environment: %w[GLUETUN_USER], name: 'gluetun_user', default: nil,
                      blank_is_absent: true, write: :secret, secret: true },
      gluetun_pass: { environment: %w[GLUETUN_PASS], name: 'gluetun_pass', default: nil,
                      blank_is_absent: true, write: :secret, secret: true },
      opnsense_api_key: { environment: %w[OPN_API_KEY], name: 'opnsense_api_key', default: nil,
                          blank_is_absent: true, preserve_blank: true, write: :secret, secret: true },
      opnsense_api_secret: { environment: %w[OPN_API_SECRET], name: 'opnsense_api_secret', default: nil,
                             blank_is_absent: true, preserve_blank: true, write: :secret, secret: true },
      qbit_api_key: { environment: %w[QBIT_API_KEY], name: 'qbit_api_key', default: nil,
                      blank_is_absent: true, write: :secret, secret: true },
      qbit_user: { environment: %w[QBIT_USER], name: 'qbit_user', default: nil,
                   blank_is_absent: true, preserve_blank: true, write: :secret, secret: true },
      qbit_pass: { environment: %w[QBIT_PASS], name: 'qbit_pass', default: nil,
                   blank_is_absent: true, preserve_blank: true, write: :secret, secret: true }
    }.transform_values(&:freeze).freeze
    SECRET_NAMES = DEFINITIONS.values.filter_map { |definition| definition[:name] if definition[:secret] }.freeze
    private_constant :DEFINITIONS, :SECRET_NAMES

    def initialize(environment: ENV, encryption_key_path: SettingsEncryptionKey::DEFAULT_PATH)
      @environment = environment
      @encryption_key_path = encryption_key_path
      @resolutions = {}
    end

    # Source identifies the selected input layer, including legacy blanks and numeric normalization.
    # Invalid authoritative values never cause a lower-precedence layer to be selected.
    def resolve(key)
      @resolutions[key] ||= resolve_setting(DEFINITIONS.fetch(key))
    end

    def value(key) = resolve(key).value

    # Never inspect or serialize the injected environment or plaintext-bearing caches.
    def inspect = "#<#{self.class.name}>"
    alias to_s inspect
    def as_json(*) = inspect

    def pretty_print(printer)
      printer.text(inspect)
    end

    def set(key, value)
      definition = write_definition(key)
      persist(definition, canonical_database_value(definition, value))
      @resolutions.delete(key)
      resolve(key)
    end

    def delete(key)
      definition = write_definition(key)
      Setting.where(name: definition.fetch(:name)).delete
      @resolutions.delete(key)
      resolve(key)
    end

    def self.validate_loop_frequency(value)
      frequency = Integer(value, exception: false)
      frequency&.positive? ? frequency : DEFINITIONS[:loop_freq][:default]
    end

    def self.validate_required_attempts(value)
      attempts = value&.to_i
      attempts&.between?(1, 10) ? attempts : DEFINITIONS[:required_attempts][:default]
    end

    private

    def write_definition(key)
      DEFINITIONS.fetch(key) { raise ValidationError, 'Unsupported setting key.', cause: nil }
    end

    def resolve_setting(definition)
      value, source, environment_name, environment_override = selected_value(definition)
      value = case definition[:read]
              when :loop_frequency then self.class.validate_loop_frequency(value)
              when :required_attempts then self.class.validate_required_attempts(value)
              when :downcase then value&.to_s&.downcase
              when :boolean then value.to_s.downcase == 'true'
              else value
              end
      Resolution.new(value: value.freeze, source: source, environment_name: environment_name,
                     environment_override: environment_override, secret: definition[:secret] == true)
    end

    def selected_value(definition)
      environment = environment_selection(definition)
      return environment if environment

      setting = Setting[name: definition.fetch(:name)]
      return [database_value(definition, setting), :database, nil, false] if setting

      # Blank placeholders permit DB overrides but retain their legacy behavior without an override.
      legacy_blank = environment_selection(definition, include_blank: true) if definition[:preserve_blank]
      legacy_blank || [definition.fetch(:default), :default, nil, false]
    end

    def environment_selection(definition, include_blank: false)
      name = definition.fetch(:environment).find do |environment_name|
        @environment.key?(environment_name) &&
          (include_blank || !definition[:blank_is_absent] || !@environment[environment_name].to_s.strip.empty?)
      end
      [@environment[name], :environment, name, !include_blank] if name
    end

    def database_value(definition, setting)
      definition[:secret] ? encryption.decrypt(definition.fetch(:name), setting.value) : setting.value
    end

    def canonical_database_value(definition, value)
      canonical = SettingsValidation.canonical_value(definition, value)
      return canonical unless definition[:secret]

      encryption.encrypt(definition.fetch(:name), canonical) { Setting.where(name: SECRET_NAMES).any? }
    end

    def persist(definition, value)
      Setting.dataset.insert_conflict(target: :name, update: { value: value })
             .insert(name: definition.fetch(:name), value: value)
    rescue Sequel::DatabaseError
      raise unless definition[:secret]

      raise ConfigurationError, 'Database credential could not be stored.', cause: nil
    end

    def encryption
      @encryption ||= SettingsEncryption.new(key_path: @encryption_key_path)
    end
  end
end
