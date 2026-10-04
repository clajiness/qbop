require_relative 'proton'
require_relative 'gluetun'

module Service
  # Port sources expose name and current_port, returning an Integer or nil when unavailable.
  # Acquisition errors propagate to the job's existing logging and recovery logic.
  module PortSource
    class ConfigurationError < StandardError; end

    def self.name(config)
      source = config.fetch(:port_source, 'proton')
      return source if %w[proton gluetun].include?(source)

      raise ConfigurationError, 'PORT_SOURCE must be proton or gluetun'
    end

    def self.build(helpers, config)
      case name(config)
      when 'proton'
        Proton.new(helpers, gateway: config[:proton_gateway])
      when 'gluetun'
        Gluetun.new(config)
      end
    end
  end
end
