class Stat < Sequel::Model # rubocop:disable Style/Documentation
  Snapshot = Data.define(:source_id, :source_name, :current_port, :same_port, :updated_at, :last_checked) do
    def [](key)
      public_send(key)
    end
  end

  many_to_one :source

  def self.by_source_id
    all.to_h { |stat| [stat.source_id, stat.to_snapshot] }
  end

  def self.by_source_name
    source_names = Source.all.to_h { |source| [source.id, source.name] }

    all.to_h { |stat| [source_names[stat.source_id], stat.to_snapshot(source_names[stat.source_id])] }
  end

  def to_snapshot(source_name = source&.name)
    Snapshot.new(
      source_id: source_id,
      source_name: source_name,
      current_port: current_port,
      same_port: same_port,
      updated_at: updated_at,
      last_checked: last_checked
    )
  end
end
