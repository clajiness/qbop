module Service
  # Resolves the supported non-secret settings once per instance, without writing overrides.
  class Settings
    Resolution = Data.define(:value, :source)

    DEFINITIONS = {
      loop_freq: { environment: 'LOOP_FREQ', name: 'loop_freq', default: 45, blank_is_absent: true },
      required_attempts: { environment: 'REQUIRED_ATTEMPTS', name: 'required_attempts', default: 3,
                           blank_is_absent: true },
      port_source: { environment: 'PORT_SOURCE', name: 'port_source', default: 'proton', blank_is_absent: false },
      proton_gateway: { environment: 'PROTON_GATEWAY', name: 'proton_gateway', default: '10.2.0.1',
                        blank_is_absent: true }
    }.transform_values(&:freeze).freeze
    private_constant :DEFINITIONS

    def initialize(environment: ENV)
      @environment = environment
      @resolutions = {}
    end

    # Source identifies the authoritative input layer, including numeric inputs normalized to a default.
    # Invalid authoritative values never cause a lower-precedence layer to be selected.
    def resolve(key)
      @resolutions[key] ||= resolve_setting(key, DEFINITIONS.fetch(key))
    end

    def value(key)
      resolve(key).value
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

    def resolve_setting(key, definition)
      value, source = selected_value(definition)
      value = case key
              when :loop_freq then self.class.validate_loop_frequency(value)
              when :required_attempts then self.class.validate_required_attempts(value)
              else value
              end
      Resolution.new(value: value.freeze, source: source)
    end

    def selected_value(definition)
      environment_name = definition.fetch(:environment)
      value = @environment[environment_name]
      if @environment.key?(environment_name) && !(definition[:blank_is_absent] && value.to_s.strip.empty?)
        return [value, :environment]
      end

      setting = Setting[name: definition.fetch(:name)]
      return [setting.value, :database] if setting

      [definition.fetch(:default), :default]
    end
  end
end
