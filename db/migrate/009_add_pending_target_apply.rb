Sequel.migration do
  change do
    alter_table(:counters) do
      add_column :pending_apply_port, Integer
      # A history boundary, not a foreign key: history retention must not erase pending work.
      add_column :pending_apply_transition_id, Integer
    end
  end
end
