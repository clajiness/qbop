require 'bundler/setup'
Bundler.require(:default)
Dir['./service/*.rb'].sort.each { |file| require_relative file }

helpers = Service::Helpers.new

# collect env variables in a config variable
config = helpers.env_variables

# collect version number of qbop in a script_version variable
script_version = helpers.version

# set up logger
@logger = Logger.new('log/qbop.log', 10, 1_024_000)
@logger.info("starting qbop v#{script_version}")
@logger.info('----------')

# DO SOME WORK!

# changed port counter
# if forwarded port from Proton changes, wait for x attempts before actually changing port
counter = { port: nil, opnsense_attempt: 1, opnsense_change: false, qbit_attempt: 1, qbit_change: false }

# start the loop
loop do
  @logger.info('start of loop')

  # Proton section
  begin
    # create Proton object
    proton ||= Service::Proton.new

    # make natpmpc call to proton
    response = proton.proton_natpmpc(config[:proton_gateway])

    # raise error if stderr is not empty
    raise StandardError, response[:stderr].chomp unless response[:stderr].empty?

    # get proton response from standard output
    proton_response = response[:stdout]

    # parse natpmpc response
    forwarded_port = proton.parse_proton_response(proton_response.chomp)

    # sleep and restart loop if forwarded port isn't returned
    if forwarded_port.nil?
      @logger.error(
        "Proton didn't return a forwarded port. Sleeping for #{config[:loop_freq].to_i} seconds and trying again."
      )
      sleep config[:loop_freq].to_i
      next
    else
      @logger.info("Proton returned the forwarded port: #{forwarded_port}")
    end
  rescue StandardError => e
    @logger.error('Proton has returned an error:')
    @logger.error(e)

    @logger.info("sleeping for #{config[:loop_freq].to_i} seconds and trying again")
    sleep config[:loop_freq].to_i
    next
  end

  # OPNsense section
  begin
    # create OPNsense object
    opnsense ||= Service::Opnsense.new(config)

    # get OPNsense proton alias uuid
    uuid = opnsense.get_alias_uuid

    # get OPNsense alias value
    alias_port = opnsense.get_alias_value(uuid)

    if alias_port != forwarded_port
      @logger.info("OPNsense port #{alias_port} does not match Proton forwarded port #{forwarded_port}. Attempt #{counter[:opnsense_attempt]} of 3.") # rubocop:disable Layout/LineLength

      # after 3 attempts, if the ports still don't match, set the OPNsense port to be updated
      counter[:opnsense_change] = true if counter[:port] == forwarded_port && counter[:opnsense_attempt] > 2
    else
      # reset counter if ports match
      counter[:opnsense_attempt] = 1 if counter[:opnsense_attempt] != 1
      @logger.info("OPNsense port #{alias_port} matches Proton forwarded port #{forwarded_port}")
    end

    # keep track of how many times the OPNsense and Proton ports don't match
    if alias_port != forwarded_port
      counter[:port] = forwarded_port
      counter[:opnsense_attempt] += 1
    end

    # set OPNsense Proton port alias if counter is set to true
    if counter[:opnsense_change] == true
      # set OPNsense port alias
      response = opnsense.set_alias_value(forwarded_port, uuid)

      if response.code == '200'
        @logger.info("OPNsense alias has been updated to #{forwarded_port}")

        # apply changes
        changes = opnsense.apply_changes

        if changes.code == '200'
          @logger.info('OPNsense alias applied successfully')

          # reset counter
          counter[:opnsense_change] = false
          counter[:opnsense_attempt] = 1
        end
      end
    end
  rescue StandardError => e
    @logger.error('OPNsense has returned an error:')
    @logger.error(e)

    @logger.info("sleeping for #{config[:loop_freq].to_i} seconds and trying again")
    sleep config[:loop_freq].to_i
    next
  end

  # qBit section
  if config[:qbit_skip]&.to_s&.downcase == 'true'
    # ignore qBit section
    @logger.info('qBit check skipped')
  else
    begin
      # create qBit object
      qbit ||= Service::Qbit.new(config)

      # get sid from qBit
      sid = qbit.qbt_auth_login

      # get port from qBit
      qbt_port = qbit.qbt_app_preferences(sid)

      if qbt_port != forwarded_port
        @logger.info("qBit port #{qbt_port} does not match Proton forwarded port #{forwarded_port}. Attempt #{counter[:qbit_attempt]} of 3.") # rubocop:disable Layout/LineLength

        # after 3 attempts, if the ports still don't match, set the qBit port to be updated
        counter[:qbit_change] = true if counter[:port] == forwarded_port && counter[:qbit_attempt] > 2
      else
        # reset counter if ports match
        counter[:qbit_attempt] = 1 if counter[:qbit_attempt] != 1
        @logger.info("qBit port #{qbt_port} matches Proton forwarded port #{forwarded_port}")
      end

      # keep track of how many times the qBit and Proton ports don't match
      if qbt_port != forwarded_port
        counter[:port] = forwarded_port
        counter[:qbit_attempt] += 1
      end

      # set qBit port if counter is set to true
      if counter[:qbit_change] == true
        # set qBit port
        response = qbit.qbt_app_set_preferences(forwarded_port, sid)

        if response.code == '200'
          @logger.info("qBit's port has been updated to #{forwarded_port}")

          # reset counter
          counter[:qbit_change] = false
          counter[:qbit_attempt] = 1
        else
          @logger.error("qBit's port was not updated")
        end
      end
    rescue StandardError => e
      @logger.error('qBit has returned an error:')
      @logger.error(e)

      @logger.info("sleeping for #{config[:loop_freq].to_i} seconds and trying again")
      sleep config[:loop_freq].to_i
      next
    end
  end

  # sleep before looping again
  @logger.info('end of loop')
  @logger.info("sleeping for #{config[:loop_freq].to_i} seconds...")
  @logger.info('----------')
  sleep config[:loop_freq].to_i
end
# ----------
