Sequel.migration do
  change do
    create_table(:port_transitions) do
      primary_key :id
      Integer :previous_port
      Integer :new_port, null: false
      DateTime :detected_at, null: false
      DateTime :opnsense_synced_at
      DateTime :qbit_synced_at
      Boolean :opnsense_skipped, default: false, null: false
      Boolean :qbit_skipped, default: false, null: false

      index :detected_at
    end
  end
end
