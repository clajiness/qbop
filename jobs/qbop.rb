# Qbop is a class responsible for managing the synchronization of port forwarding settings
# between ProtonVPN, OPNsense firewall, and qBittorrent.
class Qbop # rubocop:disable Metrics/ClassLength
  include SuckerPunch::Job
  SuckerPunch.shutdown_timeout = 1

  def perform # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
    # create Helpers object
    helpers = Service::Helpers.new

    # collect env variables in a config variable
    config = helpers.env_variables

    # set job started at timestamp
    helpers.set_job_started_at

    # create Proton objects
    proton = Service::Proton.new(helpers)
    proton_data = Source.find(name: 'proton')

    # create OPNsense objects
    opnsense = Service::Opnsense.new(config)
    opnsense_data = Source.find(name: 'opnsense')

    # create qBit objects
    qbit = Service::Qbit.new(config)
    qbit_data = Source.find(name: 'qbit')

    # set up logger
    @logger = Logger.new('log/qbop.log', 10, 1_024_000)
    @logger.info("starting qbop #{config[:script_version]}")
    @logger.info("the tool will loop every #{config[:loop_freq]} seconds")
    @logger.info('----------')

    # start the loop
    loop do
      @logger.info("start of loop (#{config[:script_version]})")

      # Proton section
      begin
        # make natpmpc call to proton
        response = proton.natpmpc(config[:proton_gateway])

        # raise error if natpmpc call returns an error
        raise StandardError, response[:stderr].chomp unless response[:stderr].empty?

        # get proton response from output
        proton_response = response[:stdout]

        # parse natpmpc response
        forwarded_port = proton.parse_response(proton_response.chomp)

        # set Proton as checked
        proton_data.set_last_checked if forwarded_port

        if forwarded_port.nil?
          # if forwarded port isn't returned
          @logger.error("Proton didn't return a forwarded port.")
        elsif forwarded_port == proton_data.get_current_port
          # if forwarded port matches the current port
          @logger.info("Proton returned the forwarded port #{forwarded_port}")

          # set proton_updated_at timestamp if it is unknown
          proton_data.set_updated_at if proton_data.get_updated_at == 'unknown'

          # if proton port hasn't changed, set tracking value
          proton_data.set_same_port
        else
          # if forwarded port does not match the current port
          @logger.info("Proton returned the new forwarded port #{forwarded_port}")

          # set Proton port in stats
          proton_data.set_current_port(forwarded_port)
          proton_data.set_updated_at
        end
      rescue StandardError => e
        @logger.error('Proton has returned an error:')
        @logger.error(e)
      end

      # OPNsense section
      if helpers.true?(config[:opnsense_skip])
        # ignore OPNsense section
        @logger.info('OPNsense check skipped')
      else
        begin
          # get OPNsense proton alias uuid
          uuid = opnsense.get_alias_uuid

          # get OPNsense alias value
          alias_port = opnsense.get_alias_value(uuid)

          # set OPNsense as checked
          opnsense_data.set_last_checked if alias_port

          if !(1024..65_535).include?(forwarded_port.to_i)
            @logger.info('OPNsense rejected Proton\'s forwarded port as it is not within a valid range of 1024-65535')
          elsif alias_port != forwarded_port
            # increment counter
            opnsense_data.increment_attempt

            # after x attempts, if the ports still don't match, set the OPNsense port to be updated
            opnsense_data.change if opnsense_data.attempt >= helpers.env_variables[:required_attempts]

            @logger.info("OPNsense port #{alias_port} does not match Proton forwarded port #{forwarded_port}. Attempt #{opnsense_data.attempt} of #{helpers.env_variables[:required_attempts]}.") # rubocop:disable Layout/LineLength
          else
            # reset counter if ports match
            counter.reset_opnsense_attempt if opnsense_data.attempt != 0
            @logger.info("OPNsense port #{alias_port} matches Proton forwarded port #{forwarded_port}")

            # set OPNsense port in stats
            opnsense_data.set_current_port(forwarded_port) if forwarded_port.to_i != opnsense_data.get_current_port

            # set opn_updated_at timestamp if it is unknown
            opnsense_data.set_updated_at if opnsense_data.get_updated_at == 'unknown'

            # if opn port hasn't changed, set tracking value
            opnsense_data.set_same_port
          end

          # set OPNsense Proton port alias if counter is set to true
          if opnsense_data.change?
            # set OPNsense port alias
            response = opnsense.set_alias_value(forwarded_port, uuid)

            if response.status == 200
              @logger.info("OPNsense alias has been updated to #{forwarded_port}")

              # apply changes
              changes = opnsense.apply_changes

              if changes.status == 200 # rubocop:disable Metrics/BlockNesting
                @logger.info('OPNsense alias applied successfully')

                # reset counter
                opnsense_data.reset_change
                opnsense_data.reset_attempt

                # set OPNsense port in stats
                opnsense_data.set_current_port(forwarded_port)
                opnsense_data.set_updated_at
              else
                @logger.error("OPNsense's change was not applied - response code: #{changes.status}")
              end
            else
              @logger.error("OPNsense's alias was not updated - response code: #{response.status}")
            end
          end
        rescue StandardError => e
          @logger.error('OPNsense has returned an error:')
          @logger.error(e)
        end
      end

      # qBit section
      if helpers.true?(config[:qbit_skip])
        # ignore qBit section
        @logger.info('qBit check skipped')
      else
        begin
          # get sid from qBit
          sid = qbit.qbt_auth_login

          # get port from qBit
          qbt_port = qbit.qbt_app_preferences(sid)

          # set qBit as checked
          qbit_data.set_last_checked if qbt_port

          if !(1024..65_535).include?(forwarded_port.to_i)
            @logger.info('qBit rejected Proton\'s forwarded port as it is not within a valid range of 1024-65535')
          elsif qbt_port != forwarded_port
            # increment counter
            qbit_data.increment_attempt

            # after x attempts, if the ports still don't match, set the qBit port to be updated
            qbit_data.change if qbit_data.attempt >= helpers.env_variables[:required_attempts]

            @logger.info("qBit port #{qbt_port} does not match Proton forwarded port #{forwarded_port}. Attempt #{qbit_data.attempt} of #{helpers.env_variables[:required_attempts]}.") # rubocop:disable Layout/LineLength
          else
            # reset counter if ports match
            qbit_data.reset_attempt if qbit_data.attempt != 0
            @logger.info("qBit port #{qbt_port} matches Proton forwarded port #{forwarded_port}")

            # set qBit port in stats
            qbit_data.set_current_port(forwarded_port) if forwarded_port.to_i != qbit_data.get_current_port

            # set qBit_updated_at timestamp if it is unknown
            qbit_data.set_updated_at if qbit_data.get_updated_at == 'unknown'

            # if qBit port hasn't changed, set tracking value
            qbit_data.set_same_port
          end

          # set qBit port if counter is set to true
          if qbit_data.change?
            # set qBit port
            response = qbit.qbt_app_set_preferences(forwarded_port, sid)

            if response.status == 200
              @logger.info("qBit port has been updated to #{forwarded_port}")

              # reset counter
              qbit_data.reset_change
              qbit_data.reset_attempt

              # set qBit port in stats
              qbit_data.set_current_port(forwarded_port)
              qbit_data.set_updated_at
            else
              @logger.error("qBit port was not updated - response code: #{response.status}")
            end
          end
        rescue StandardError => e
          @logger.error('qBit has returned an error:')
          @logger.error(e)
        end
      end

      # sleep before looping again
      @logger.info('end of loop')
      @logger.info("sleeping for #{config[:loop_freq]} seconds...")
      @logger.info('----------')
      sleep config[:loop_freq]
    end
  end
end
