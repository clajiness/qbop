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
    eager(:source).all.to_h { |stat| [stat.source.name, stat.to_snapshot] }
  end

  def to_snapshot
    Snapshot.new(
      source_id: source_id,
      source_name: source&.name,
      current_port: current_port,
      same_port: same_port,
      updated_at: updated_at,
      last_checked: last_checked
    )
  end
end
