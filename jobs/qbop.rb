class Qbop # rubocop:disable Metrics/ClassLength,Style/Documentation
  include SuckerPunch::Job

  def perform # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
    # create Helpers object
    helpers = Service::Helpers.new

    # collect env variables in a config variable
    config = helpers.env_variables

    # set loop frequency
    loop_frequency = helpers.parse_loop_frequency(config[:loop_freq])

    # track the number of attempts to change the port in opnsense and qBit
    counter = Service::Counter.new

    # track the current port for Proton, OPNsense, and qBit
    stats = Service::Status.new

    # set up logger
    @logger = Logger.new('./data/log/qbop.log', 10, 1_024_000)
    @logger.info("starting qbop #{config[:script_version]}")
    @logger.info("the tool will loop every #{loop_frequency} seconds")
    @logger.info('----------')

    # start the loop
    loop do
      @logger.info("start of loop (#{config[:script_version]})")

      # Proton section
      begin
        # create Proton object
        proton ||= Service::Proton.new

        # make natpmpc call to proton
        response = proton.proton_natpmpc(config[:proton_gateway])

        # raise error if natpmpc call returns an error
        raise StandardError, response[:stderr].chomp unless response[:stderr].empty?

        # get proton response from output
        proton_response = response[:stdout]

        # parse natpmpc response
        forwarded_port = proton.parse_proton_response(proton_response.chomp)

        # sleep and restart loop if forwarded port isn't returned
        if forwarded_port.nil?
          @logger.error(
            "Proton didn't return a forwarded port. Sleeping for #{loop_frequency} seconds and trying again."
          )
          sleep loop_frequency
          next
        else
          @logger.info("Proton returned the forwarded port #{forwarded_port}")

          # set Proton port in stats
          stats.set_proton_current_port(forwarded_port)
        end
      rescue StandardError => e
        @logger.error('Proton has returned an error:')
        @logger.error(e)

        @logger.info("sleeping for #{loop_frequency} seconds and trying again")
        sleep loop_frequency
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
          # increment counter
          counter.increment_opnsense_attempt

          # after x attempts, if the ports still don't match, set the OPNsense port to be updated
          counter.change_opnsense if counter.opnsense_attempt >= counter.required_attempts

          @logger.info("OPNsense port #{alias_port} does not match Proton forwarded port #{forwarded_port}. Attempt #{counter.opnsense_attempt} of #{counter.required_attempts}.") # rubocop:disable Layout/LineLength
        else
          # reset counter if ports match
          counter.reset_opnsense_attempt if counter.opnsense_attempt != 0
          @logger.info("OPNsense port #{alias_port} matches Proton forwarded port #{forwarded_port}")
        end

        # set OPNsense Proton port alias if counter is set to true
        if counter.opnsense_change?
          # set OPNsense port alias
          response = opnsense.set_alias_value(forwarded_port, uuid)

          if response.status == 200
            @logger.info("OPNsense alias has been updated to #{forwarded_port}")

            # apply changes
            changes = opnsense.apply_changes

            if changes.status == 200
              @logger.info('OPNsense alias applied successfully')

              # reset counter
              counter.reset_opnsense_change
              counter.reset_opnsense_attempt

              # set OPNsense port in stats
              stats.set_opn_current_port(forwarded_port)
              stats.set_opn_updated_at
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

        @logger.info("sleeping for #{loop_frequency} seconds and trying again")
        sleep loop_frequency
        next
      end

      # qBit section
      if helpers.skip_qbit?(config[:qbit_skip])
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
            # increment counter
            counter.increment_qbit_attempt

            # after x attempts, if the ports still don't match, set the qBit port to be updated
            counter.change_qbit if counter.qbit_attempt >= counter.required_attempts

            @logger.info("qBit port #{qbt_port} does not match Proton forwarded port #{forwarded_port}. Attempt #{counter.qbit_attempt} of #{counter.required_attempts}.") # rubocop:disable Layout/LineLength
          else
            # reset counter if ports match
            counter.reset_qbit_attempt if counter.qbit_attempt != 0
            @logger.info("qBit port #{qbt_port} matches Proton forwarded port #{forwarded_port}")
          end

          # set qBit port if counter is set to true
          if counter.qbit_change?
            # set qBit port
            response = qbit.qbt_app_set_preferences(forwarded_port, sid)

            if response.status == 200
              @logger.info("qBit port has been updated to #{forwarded_port}")

              # reset counter
              counter.reset_qbit_change
              counter.reset_qbit_attempt

              # set qBit port in stats
              stats.set_qbit_current_port(forwarded_port)
              stats.set_qbit_updated_at
            else
              @logger.error("qBit port was not updated - response code: #{response.status}")
            end
          end
        rescue StandardError => e
          @logger.error('qBit has returned an error:')
          @logger.error(e)

          @logger.info("sleeping for #{loop_frequency} seconds and trying again")
          sleep loop_frequency
          next
        end
      end

      # sleep before looping again
      @logger.info('end of loop')
      @logger.info("sleeping for #{loop_frequency} seconds...")
      @logger.info('----------')
      sleep loop_frequency
    end
  end
end
