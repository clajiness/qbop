Sequel.migration do # rubocop:disable Metrics/BlockLength
  change do
    create_table(:services) do
      primary_key :id
      String :name, null: false, unique: true
    end

    create_table(:counters) do
      primary_key :id
      foreign_key :service_id, :services
      String :name, null: false, unique: true
      Integer :attempt, default: 0, null: false
      Boolean :change, default: false, null: false
    end

    create_table(:stats) do
      primary_key :id
      foreign_key :service_id, :services
      Integer :current_port, default: 0, null: false
      String :updated_at, text: true
      String :last_checked, text: true
      Integer :same_port, default: 0, null: false
    end

    create_table(:notifications) do
      primary_key :id
      String :info, null: false
      Boolean :active, default: false
    end
  end
end
