class PortTransition < Sequel::Model # rubocop:disable Style/Documentation
  RETENTION_LIMIT = 500
  Page = Data.define(:records, :total_records, :current_page, :per_page, :total_pages, :from, :to)
  SYNC_COLUMNS = {
    'opnsense' => {
      synced_at: :opnsense_synced_at,
      error_at: :opnsense_error_at,
      skipped: :opnsense_skipped
    }.freeze,
    'qbit' => {
      synced_at: :qbit_synced_at,
      error_at: :qbit_error_at,
      skipped: :qbit_skipped
    }.freeze
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
    columns = SYNC_COLUMNS.fetch(source.to_s)
    transition = latest_for_port(port)
    return unless transition
    return transition if transition.public_send(columns[:synced_at]) && !transition.public_send(columns[:error_at])

    transition.update(columns[:synced_at] => at, columns[:error_at] => nil)
    transition
  end

  def self.mark_error(source, port, at: Time.now)
    columns = SYNC_COLUMNS.fetch(source.to_s)
    transition = latest_for_port(port)
    return unless transition

    transition.update(columns[:synced_at] => nil, columns[:error_at] => at)
    transition
  end

  def self.sync_error?(source, port)
    latest_for_port(port)&.sync_status(source) == 'error'
  end

  def self.paginate(page:, per_page:) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    total_records = count
    total_pages = [((total_records + per_page - 1) / per_page), 1].max
    current_page = page.clamp(1, total_pages)
    offset = (current_page - 1) * per_page
    records = order(Sequel.desc(:detected_at), Sequel.desc(:id)).limit(per_page, offset).all

    Page.new(
      records: records,
      total_records: total_records,
      current_page: current_page,
      per_page: per_page,
      total_pages: total_pages,
      from: total_records.zero? ? 0 : offset + 1,
      to: offset + records.length
    )
  end

  def sync_status(source)
    columns = SYNC_COLUMNS.fetch(source.to_s)
    return 'skipped' if public_send(columns[:skipped])
    return 'synced' if public_send(columns[:synced_at])
    return 'error' if public_send(columns[:error_at])

    'pending'
  end

  def self.latest_for_port(port)
    where(new_port: port.to_i).order(Sequel.desc(:id)).first
  end
  private_class_method :latest_for_port

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
