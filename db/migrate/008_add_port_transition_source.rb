Sequel.migration do
  change do
    alter_table(:port_transitions) do
      add_column :source_name, String, null: false, default: 'proton'
    end
  end
end
