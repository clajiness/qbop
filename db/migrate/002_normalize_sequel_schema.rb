Sequel.migration do # rubocop:disable Metrics/BlockLength
  up do # rubocop:disable Metrics/BlockLength
    normalize_rows = lambda do |table|
      dataset = self[table]

      dataset.where(source_id: nil).delete
      dataset.exclude(source_id: self[:sources].select(:id)).delete

      ids_to_keep = dataset.select_group(:source_id).select_append { min(id).as(:id) }
      dataset.exclude(id: ids_to_keep.select(:id)).delete
    end

    unique_source_id_index = lambda do |table|
      indexes(table).any? do |_name, index|
        index[:unique] && index[:columns] == [:source_id]
      end
    end

    normalize_rows.call(:stats)
    normalize_rows.call(:counters)

    self[:stats].where(updated_at: ['unknown', '']).update(updated_at: nil)
    self[:stats].where(last_checked: ['unknown', '']).update(last_checked: nil)

    stats_schema = schema(:stats).to_h
    stats_needs_time_type = stats_schema[:updated_at][:type] != :datetime ||
                            stats_schema[:last_checked][:type] != :datetime
    stats_needs_not_null = stats_schema[:source_id][:allow_null]
    stats_needs_unique = !unique_source_id_index.call(:stats)

    if stats_needs_time_type || stats_needs_not_null || stats_needs_unique
      alter_table(:stats) do
        set_column_type :updated_at, DateTime if stats_needs_time_type
        set_column_type :last_checked, DateTime if stats_needs_time_type
        set_column_not_null :source_id if stats_needs_not_null
        add_unique_constraint :source_id if stats_needs_unique
      end
    end

    counters_schema = schema(:counters).to_h
    counters_needs_not_null = counters_schema[:source_id][:allow_null]
    counters_needs_unique = !unique_source_id_index.call(:counters)

    if counters_needs_not_null || counters_needs_unique
      alter_table(:counters) do
        set_column_not_null :source_id if counters_needs_not_null
        add_unique_constraint :source_id if counters_needs_unique
      end
    end
  end

  down do
    alter_table(:stats) do
      set_column_type :updated_at, String
      set_column_type :last_checked, String
    end
  end
end
