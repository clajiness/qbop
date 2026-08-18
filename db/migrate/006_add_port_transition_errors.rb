Sequel.migration do
  up do
    alter_table(:port_transitions) do
      add_column :opnsense_error_at, DateTime
      add_column :qbit_error_at, DateTime
    end
  end

  down do
    alter_table(:port_transitions) do
      drop_column :opnsense_error_at
      drop_column :qbit_error_at
    end
  end
end
