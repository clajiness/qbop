require_relative '../service/port_source'

# Qbop is a class responsible for managing the synchronization of port forwarding settings
# between the selected port source, OPNsense firewall, and qBittorrent.
class Qbop # rubocop:disable Metrics/ClassLength
  include SuckerPunch::Job
  SuckerPunch.shutdown_timeout = 1

  def perform
    initialize_dependencies
    log_startup

    loop do
      run_loop_iteration
    end
  end

  private

  def initialize_dependencies
    @helpers = Service::Helpers.new
    @config = @helpers.env_variables
    @port_source = Service::PortSource.build(@helpers, @config)
    @opnsense = Service::Opnsense.new(@config)
    @qbit = Service::Qbit.new(@config)
    @port_data = Source[name: @port_source.name]
    @opnsense_data = Source[name: 'opnsense']
    @qbit_data = Source[name: 'qbit']
    @logger = @helpers.logger_instance
  end

  def log_startup
    @logger.info("starting qbop #{@config[:script_version]} (#{@config[:commit_sha]})")
    @logger.info("the tool will loop every #{@config[:loop_freq]} seconds")
    @logger.info('----------')
  end

  def run_loop_iteration
    @logger.info("start of loop (#{@config[:script_version]})")

    forwarded_port = handle_port_forwarding
    synchronize_port(forwarded_port)

    # Failed checks can make the time-based connection indicators stale even
    # when no source row changed. Re-evaluate them after the completed checks.
    Framework::Events.publish(:status_changed)

    @logger.info('end of loop')
    @logger.info("sleeping for #{@config[:loop_freq]} seconds...")
    @logger.info('----------')
    sleep @config[:loop_freq]
  end

  def synchronize_port(forwarded_port)
    return if forwarded_port.nil?

    handle_opnsense(forwarded_port)
    handle_qbit(forwarded_port)
  end

  def port_source_label
    @port_source.name.capitalize
  end

  def handle_port_forwarding # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    forwarded_port = @port_source.current_port
    @port_data.set_last_checked if forwarded_port

    if forwarded_port.nil?
      @logger.error("#{port_source_label} didn't return a forwarded port.")
    elsif forwarded_port == @port_data.get_current_port
      @logger.info("#{port_source_label} returned the forwarded port #{forwarded_port}")
      @port_data.set_updated_at unless @port_data.updated?
      @port_data.set_same_port
    else
      @logger.info("#{port_source_label} returned the new forwarded port #{forwarded_port}")
      record_port_transition(@port_data.get_current_port, forwarded_port)
      @port_data.set_current_port(forwarded_port)
      @port_data.set_updated_at
    end

    forwarded_port
  rescue StandardError => e
    log_error(port_source_label, e)
    nil
  end

  def handle_opnsense(forwarded_port) # rubocop:disable Metrics/MethodLength
    if @helpers.true?(@config[:opnsense_skip])
      @logger.info('OPNsense check skipped')
      return
    end

    uuid = @opnsense.get_alias_uuid
    alias_port = @opnsense.get_alias_value(uuid)

    @opnsense_data.set_last_checked if alias_port

    return apply_opnsense_changes(forwarded_port) if opnsense_apply_retry?(alias_port, forwarded_port)

    @opnsense_data.set_current_port(alias_port)
    return unless sync_target_port(@opnsense_data, alias_port, forwarded_port, 'OPNsense', 'opnsense')

    update_opnsense_alias(forwarded_port, uuid)
  rescue StandardError => e
    log_error('OPNsense', e)
  end

  def handle_qbit(forwarded_port) # rubocop:disable Metrics/MethodLength
    if @helpers.true?(@config[:qbit_skip])
      @logger.info('qBit check skipped')
      return
    end

    qbt_port = @qbit.qbt_app_preferences

    @qbit_data.set_current_port(qbt_port)
    @qbit_data.set_last_checked if qbt_port

    return unless sync_target_port(@qbit_data, qbt_port, forwarded_port, 'qBit', 'qbit')

    update_qbit_port(forwarded_port)
  rescue StandardError => e
    log_error('qBit', e)
  end

  def sync_target_port(source_data, current_port, forwarded_port, source_name, history_source = nil) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    current_port = current_port.to_i
    forwarded_port = forwarded_port.to_i

    unless valid_forwarded_port?(forwarded_port)
      @logger.info("#{source_name} rejected #{port_source_label}'s forwarded port " \
                   'as it is not within a valid range of 1-65535')
      return false
    end

    if current_port != forwarded_port
      source_data.increment_attempt
      source_data.change if source_data.attempt >= @config[:required_attempts]
      @logger.info("#{source_name} port #{current_port} does not match #{port_source_label} forwarded port #{forwarded_port}. Attempt #{source_data.attempt} of #{@config[:required_attempts]}.") # rubocop:disable Layout/LineLength
      return source_data.change?
    end

    source_data.reset_change if source_data.change?
    source_data.reset_attempt if source_data.attempt != 0
    @logger.info("#{source_name} port #{current_port} matches #{port_source_label} forwarded port #{forwarded_port}")
    source_data.set_current_port(forwarded_port) if forwarded_port != source_data.get_current_port
    source_data.set_updated_at unless source_data.updated?
    source_data.set_same_port
    PortTransition.mark_synced(history_source, forwarded_port, source_name: @port_source.name) if history_source
    false
  end

  def update_opnsense_alias(forwarded_port, uuid)
    perform_sync_write('opnsense', forwarded_port) { @opnsense.set_alias_value(forwarded_port, uuid) }
    remember_opnsense_apply(forwarded_port)

    @logger.info("OPNsense alias has been updated to #{forwarded_port}")
    apply_opnsense_changes(forwarded_port)
  end

  def apply_opnsense_changes(forwarded_port) # rubocop:disable Metrics/MethodLength
    changes_status = perform_sync_write('opnsense', forwarded_port) { @opnsense.apply_changes.status }

    if changes_status != 200
      PortTransition.mark_error('opnsense', forwarded_port, source_name: @port_source.name)
      @logger.error("OPNsense's change was not applied - response code: #{changes_status}")
      return
    end

    @logger.info('OPNsense alias applied successfully')
    Source.db.transaction do
      mark_source_updated(@opnsense_data, forwarded_port, 'opnsense')
      PortTransition.mark_opnsense_applied(forwarded_port,
                                           transition_ids: @opnsense_data.pending_apply_transition_ids)
      @opnsense_data.clear_pending_apply
    end
  end

  def opnsense_apply_retry?(alias_port, forwarded_port) # rubocop:disable Metrics/MethodLength
    return false unless alias_port.to_i == forwarded_port.to_i

    if @opnsense_data.pending_apply_port
      if @opnsense_data.pending_apply_port != forwarded_port.to_i
        @opnsense_data.clear_pending_apply
        return false
      end

      remember_opnsense_apply(forwarded_port)
      return true
    end

    return false unless @opnsense_data.change?

    transition = PortTransition.pending_opnsense_error(forwarded_port)
    return false unless transition

    @opnsense_data.set_pending_apply(forwarded_port.to_i, [transition.id])
    remember_opnsense_apply(forwarded_port)
    true
  end

  def remember_opnsense_apply(forwarded_port)
    ids = @opnsense_data.pending_apply_port == forwarded_port.to_i ? @opnsense_data.pending_apply_transition_ids : []
    transition = PortTransition.latest_for_port(forwarded_port, @port_source.name)
    # Register only history observed while writing or retrying this target, never an ID range.
    @opnsense_data.set_pending_apply(forwarded_port.to_i, (ids + [transition&.id]).compact.uniq)
  end

  def update_qbit_port(forwarded_port)
    response_status = perform_sync_write('qbit', forwarded_port) do
      @qbit.qbt_app_set_preferences(forwarded_port).status
    end

    if response_status != 200
      PortTransition.mark_error('qbit', forwarded_port, source_name: @port_source.name)
      @logger.error("qBit port was not updated - response code: #{response_status}")
      return
    end

    @logger.info("qBit port has been updated to #{forwarded_port}")
    mark_source_updated(@qbit_data, forwarded_port, 'qbit')
  end

  def mark_source_updated(source_data, forwarded_port, history_source)
    source_data.reset_change
    source_data.reset_attempt
    source_data.set_current_port(forwarded_port)
    source_data.set_updated_at
    PortTransition.mark_synced(history_source, forwarded_port, source_name: @port_source.name)
  end

  def perform_sync_write(history_source, forwarded_port)
    yield
  rescue StandardError
    PortTransition.mark_error(history_source, forwarded_port, source_name: @port_source.name)
    raise
  end

  def record_port_transition(previous_port, new_port)
    PortTransition.record_transition(
      source_name: @port_source.name,
      previous_port: previous_port,
      new_port: new_port,
      opnsense_skipped: @helpers.true?(@config[:opnsense_skip]),
      qbit_skipped: @helpers.true?(@config[:qbit_skip])
    )
  end

  def valid_forwarded_port?(forwarded_port)
    (1..65_535).include?(forwarded_port.to_i)
  end

  def log_error(source_name, error)
    @logger.error("#{source_name} has returned an error:")
    @logger.error(error)
  end
end
