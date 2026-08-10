class PortTransition < Sequel::Model # rubocop:disable Style/Documentation
  RETENTION_LIMIT = 500
  SYNC_COLUMNS = {
    'opnsense' => :opnsense_synced_at,
    'qbit' => :qbit_synced_at
  }.freeze

  def self.record_transition(previous_port:, new_port:, opnsense_skipped:, qbit_skipped:, detected_at: Time.now)
    db.transaction do
      create(
        previous_port: normalize_previous_port(previous_port),
        new_port: new_port.to_i,
        detected_at: detected_at,
        opnsense_skipped: opnsense_skipped,
        qbit_skipped: qbit_skipped
      ).tap { prune! }
    end
  end

  def self.mark_synced(source, port, at: Time.now)
    column = SYNC_COLUMNS.fetch(source.to_s)
    transition = where(new_port: port.to_i).order(Sequel.desc(:id)).first
    return unless transition
    return transition if transition.public_send(column)

    transition.update(column => at)
    transition
  end

  def sync_status(source)
    source = source.to_s
    return 'skipped' if public_send("#{source}_skipped")
    return 'synced' if public_send("#{source}_synced_at")

    'pending'
  end

  def self.normalize_previous_port(port)
    port = port.to_i
    port.positive? ? port : nil
  end
  private_class_method :normalize_previous_port

  def self.prune!
    expired_ids = order(Sequel.desc(:detected_at), Sequel.desc(:id))
                  .offset(RETENTION_LIMIT)
                  .select_map(:id)
    where(id: expired_ids).delete if expired_ids.any?
  end
  private_class_method :prune!
end
