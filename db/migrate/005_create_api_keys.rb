Sequel.migration do
  up do
    create_table(:api_keys) do
      primary_key :id
      String :name, null: false
      String :token_digest, null: false
      String :token_prefix, null: false
      DateTime :created_at, null: false
      DateTime :last_used_at

      index :token_digest, unique: true
    end
  end

  down do
    drop_table(:api_keys)
  end
end
