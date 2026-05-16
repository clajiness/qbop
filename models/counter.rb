class Counter < Sequel::Model # rubocop:disable Style/Documentation
  Snapshot = Data.define(:source_id, :source_name, :attempt, :change) do
    def [](key)
      public_send(key)
    end

    def change?
      change
    end
  end

  many_to_one :source

  def self.by_source_id
    all.to_h { |counter| [counter.source_id, counter.to_snapshot] }
  end

  def self.by_source_name
    source_names = Source.all.to_h { |source| [source.id, source.name] }

    all.to_h { |counter| [source_names[counter.source_id], counter.to_snapshot(source_names[counter.source_id])] }
  end

  def to_snapshot(source_name = source&.name)
    Snapshot.new(source_id: source_id, source_name: source_name, attempt: attempt, change: change)
  end
end
