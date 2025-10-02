module Service
  class Seed # rubocop:disable Style/Documentation
    def initialize
      seed
    end

    private

    def seed
      proton_data = Source.find_or_create(name: 'proton')
      proton_data.seed_tables

      opnsense_data = Source.find_or_create(name: 'opnsense')
      opnsense_data.seed_tables

      qbit_data = Source.find_or_create(name: 'qbit')
      qbit_data.seed_tables
    end
  end
end
