Sequel.migration do # rubocop:disable Metrics/BlockLength
  change do
    create_table(:sources) do
      primary_key :id
      String :name, null: false, unique: true
    end

    create_table(:stats) do
      primary_key :id
      foreign_key :source_id, :sources
      Integer :current_port, default: 0, null: false
      Integer :same_port, default: 0, null: false
      String :updated_at
      String :last_checked
    end

    create_table(:counters) do
      primary_key :id
      foreign_key :source_id, :sources
      Integer :attempt, default: 0, null: false
      Boolean :change, default: false, null: false
    end

    create_table(:notifications) do
      primary_key :id
      String :name, null: false, unique: true
      String :info
      Boolean :active, default: false
    end
  end
end
