# Qbop is a class responsible for managing the synchronization of port forwarding settings
# between ProtonVPN, OPNsense firewall, and qBittorrent.
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
    @proton = Service::Proton.new(@helpers)
    @opnsense = Service::Opnsense.new(@config)
    @qbit = Service::Qbit.new(@config)
    @proton_data = Source[name: 'proton']
    @opnsense_data = Source[name: 'opnsense']
    @qbit_data = Source[name: 'qbit']
    @logger = @helpers.logger_instance
  end

  def log_startup
    @logger.info("starting qbop #{@config[:script_version]}")
    @logger.info("the tool will loop every #{@config[:loop_freq]} seconds")
    @logger.info('----------')
  end

  def run_loop_iteration
    @logger.info("start of loop (#{@config[:script_version]})")

    forwarded_port = handle_proton
    handle_opnsense(forwarded_port)
    handle_qbit(forwarded_port)

    @logger.info('end of loop')
    @logger.info("sleeping for #{@config[:loop_freq]} seconds...")
    @logger.info('----------')
    sleep @config[:loop_freq]
  end

  def handle_proton # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    response = @proton.natpmpc(@config[:proton_gateway])
    raise StandardError, response[:stderr].chomp unless response[:stderr].empty?

    forwarded_port = @proton.parse_response(response[:stdout].chomp)
    @proton_data.set_last_checked if forwarded_port

    if forwarded_port.nil?
      @logger.error("Proton didn't return a forwarded port.")
    elsif forwarded_port == @proton_data.get_current_port
      @logger.info("Proton returned the forwarded port #{forwarded_port}")
      @proton_data.set_updated_at if @proton_data.get_updated_at == 'unknown'
      @proton_data.set_same_port
    else
      @logger.info("Proton returned the new forwarded port #{forwarded_port}")
      @proton_data.set_current_port(forwarded_port)
      @proton_data.set_updated_at
    end

    forwarded_port
  rescue StandardError => e
    log_error('Proton', e)
    nil
  end

  def handle_opnsense(forwarded_port) # rubocop:disable Metrics/MethodLength
    if @helpers.true?(@config[:opnsense_skip])
      @logger.info('OPNsense check skipped')
      return
    end

    uuid = @opnsense.get_alias_uuid
    alias_port = @opnsense.get_alias_value(uuid)

    @opnsense_data.set_current_port(alias_port)
    @opnsense_data.set_last_checked if alias_port

    return unless sync_target_port(@opnsense_data, alias_port, forwarded_port, 'OPNsense')

    update_opnsense_alias(forwarded_port, uuid)
  rescue StandardError => e
    log_error('OPNsense', e)
  end

  def handle_qbit(forwarded_port) # rubocop:disable Metrics/MethodLength
    if @helpers.true?(@config[:qbit_skip])
      @logger.info('qBit check skipped')
      return
    end

    sid = @qbit.qbt_auth_login
    qbt_port = @qbit.qbt_app_preferences(sid)

    @qbit_data.set_current_port(qbt_port)
    @qbit_data.set_last_checked if qbt_port

    return unless sync_target_port(@qbit_data, qbt_port, forwarded_port, 'qBit')

    update_qbit_port(forwarded_port, sid)
  rescue StandardError => e
    log_error('qBit', e)
  end

  def sync_target_port(source_data, current_port, forwarded_port, source_name) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    unless valid_forwarded_port?(forwarded_port)
      @logger.info("#{source_name} rejected Proton's forwarded port as it is not within a valid range of 1024-65535")
      return false
    end

    if current_port != forwarded_port
      source_data.increment_attempt
      source_data.change if source_data.attempt >= @config[:required_attempts]
      @logger.info("#{source_name} port #{current_port} does not match Proton forwarded port #{forwarded_port}. Attempt #{source_data.attempt} of #{@config[:required_attempts]}.") # rubocop:disable Layout/LineLength
      return source_data.change?
    end

    source_data.reset_attempt if source_data.attempt != 0
    @logger.info("#{source_name} port #{current_port} matches Proton forwarded port #{forwarded_port}")
    source_data.set_current_port(forwarded_port) if forwarded_port.to_i != source_data.get_current_port
    source_data.set_updated_at if source_data.get_updated_at == 'unknown'
    source_data.set_same_port
    false
  end

  def update_opnsense_alias(forwarded_port, uuid) # rubocop:disable Metrics/MethodLength
    response = @opnsense.set_alias_value(forwarded_port, uuid)

    if response.status != 200
      @logger.error("OPNsense's alias was not updated - response code: #{response.status}")
      return
    end

    @logger.info("OPNsense alias has been updated to #{forwarded_port}")
    changes = @opnsense.apply_changes

    if changes.status != 200
      @logger.error("OPNsense's change was not applied - response code: #{changes.status}")
      return
    end

    @logger.info('OPNsense alias applied successfully')
    mark_source_updated(@opnsense_data, forwarded_port)
  end

  def update_qbit_port(forwarded_port, sid)
    response = @qbit.qbt_app_set_preferences(forwarded_port, sid)

    if response.status != 200
      @logger.error("qBit port was not updated - response code: #{response.status}")
      return
    end

    @logger.info("qBit port has been updated to #{forwarded_port}")
    mark_source_updated(@qbit_data, forwarded_port)
  end

  def mark_source_updated(source_data, forwarded_port)
    source_data.reset_change
    source_data.reset_attempt
    source_data.set_current_port(forwarded_port)
    source_data.set_updated_at
  end

  def valid_forwarded_port?(forwarded_port)
    (1024..65_535).include?(forwarded_port.to_i)
  end

  def log_error(source_name, error)
    @logger.error("#{source_name} has returned an error:")
    @logger.error(error)
  end
end
