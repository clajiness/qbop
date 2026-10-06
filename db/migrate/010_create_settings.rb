Sequel.migration do
  change do
    create_table(:settings) do
      primary_key :id
      String :name, null: false, unique: true
      String :value, text: true, null: false
    end
  end
end
