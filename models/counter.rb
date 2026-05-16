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
    eager(:source).all.to_h { |counter| [counter.source.name, counter.to_snapshot] }
  end

  def to_snapshot
    Snapshot.new(source_id: source_id, source_name: source&.name, attempt: attempt, change: change)
  end
end
