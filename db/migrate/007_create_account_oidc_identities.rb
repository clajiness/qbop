Sequel.migration do
  up do
    create_table(:account_oidc_identities) do
      primary_key :id
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String :issuer, null: false
      String :subject, null: false

      index :account_id
      # qbop has one administrator, so one subject may be linked per issuer.
      index :issuer, unique: true
    end
  end

  down do
    drop_table(:account_oidc_identities)
  end
end
