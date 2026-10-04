require_relative 'helpers'
require_relative 'port_source'

module Service
  class Seed # rubocop:disable Style/Documentation
    def initialize
      seed
    end

    private

    def seed
      port_data = Source.find_or_create(name: PortSource.name(Helpers.new.env_variables))
      port_data.seed_tables

      opnsense_data = Source.find_or_create(name: 'opnsense')
      opnsense_data.seed_tables

      qbit_data = Source.find_or_create(name: 'qbit')
      qbit_data.seed_tables
    end
  end
end
