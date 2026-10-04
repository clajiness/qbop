Sequel.migration do
  change do
    alter_table(:counters) do
      add_column :pending_apply_port, Integer
      # Explicit participant IDs (JSON), without foreign keys: pruning must not erase pending work.
      add_column :pending_apply_transition_ids, String, text: true
    end
  end
end
