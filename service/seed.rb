require_relative 'synchronization_configuration'

module Service
  class Seed # rubocop:disable Style/Documentation
    def initialize
      seed
    end

    private

    def seed
      config = SynchronizationConfiguration.resolve(Settings.new)
      port_data = Source.find_or_create(name: config.port_source)
      port_data.seed_tables

      opnsense_data = Source.find_or_create(name: 'opnsense')
      opnsense_data.seed_tables

      qbit_data = Source.find_or_create(name: 'qbit')
      qbit_data.seed_tables

      SynchronizationConfiguration.capture(config.to_h)
    end
  end
end
