Sequel.migration do
  up do
    create_table(:accounts) do
      primary_key :id, type: :Bignum
      String :email, null: false, collate: :nocase
      Integer :single_account_key, null: false, default: 1

      # All accounts occupy the same fixed slot; the unique index rejects races.
      check(single_account_key: 1)
      index :email, unique: true
      index :single_account_key, unique: true
    end

    create_table(:account_password_hashes) do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum, on_delete: :cascade
      String :password_hash, null: false
    end
  end

  down do
    drop_table(:account_password_hashes, :accounts)
  end
end
