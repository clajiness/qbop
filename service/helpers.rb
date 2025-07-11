module Service
  # The Helpers class provides utility methods for accessing environment variables
  # and parsing specific configuration values used in the application.
  class Helpers # rubocop:disable Metrics/ClassLength
    def env_variables # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
      {
        ui_mode: format_ui_mode(ENV['UI_MODE']),
        script_version: ENV['VERSION'],
        loop_freq: validate_loop_frequency(ENV['LOOP_FREQ'] || 45),
        required_attempts: validate_required_attempts(ENV['REQUIRED_ATTEMPTS'] || 3),
        proton_gateway: ENV['PROTON_GATEWAY'] || '10.2.0.1',
        opnsense_skip: ENV['OPN_SKIP'] || 'false',
        opnsense_interface_addr: ENV['OPN_INTERFACE_ADDR'],
        opnsense_api_key: ENV['OPN_API_KEY'],
        opnsense_api_secret: ENV['OPN_API_SECRET'],
        opnsense_alias_name: ENV['OPN_PROTON_ALIAS_NAME'],
        qbit_skip: ENV['QBIT_SKIP'] || 'false',
        qbit_addr: ENV['QBIT_ADDR'],
        qbit_user: ENV['QBIT_USER'],
        qbit_pass: ENV['QBIT_PASS']
      }
    end

    def format_ui_mode(ui_mode)
      ui_mode&.to_s&.downcase
    end

    def validate_loop_frequency(loop_freq)
      if loop_freq&.to_i&.positive?
        loop_freq&.to_i
      else
        45
      end
    end

    def validate_required_attempts(required_attempts)
      if required_attempts&.to_i&.between?(1, 10)
        required_attempts&.to_i
      else
        3
      end
    end

    def skip_section?(skip)
      skip&.to_s&.downcase == 'true'
    end

    def get_db_version
      user_version = 0

      SQLite3::Database.open 'data/prod.db' do |db|
        user_version = db.execute('pragma user_version;').flatten.first
      end

      user_version
    end

    def time_delta(last_checked, last_updated)
      last_checked_time = Time.new(last_checked)
      last_updated_time = Time.new(last_updated)

      seconds = last_checked_time - last_updated_time

      seconds.to_i
    rescue StandardError
      'unknown'
    end

    def time_delta_to_s(last_checked, last_updated)
      last_checked_time = Time.new(last_checked)
      last_updated_time = Time.new(last_updated)

      seconds = last_checked_time - last_updated_time

      mm, ss = seconds.to_i.divmod(60)
      hh, mm = mm.divmod(60)
      dd, hh = hh.divmod(24)

      "#{dd}d, #{hh}h, #{mm}m, #{ss}s"
    rescue StandardError
      'unknown'
    end

    def seconds_to_s(seconds)
      mm, ss = seconds.to_i.divmod(60)
      hh, mm = mm.divmod(60)
      dd, hh = hh.divmod(24)

      "#{dd}d, #{hh}h, #{mm}m, #{ss}s"
    rescue StandardError
      'unknown'
    end

    def connected_to_service?(last_checked)
      Time.new(last_checked) >= (Time.now - ((ENV['LOOP_FREQ'] || 45).to_i * 3))
    rescue StandardError
      false
    end

    def job_uptime
      job_started_at = Service::Stats.new.get_job_started_at
      time_delta(Time.now.to_s, job_started_at)
    rescue StandardError
      'unknown'
    end

    def job_uptime_to_s
      job_started_at = Service::Stats.new.get_job_started_at
      time_delta_to_s(Time.now.to_s, job_started_at)
    rescue StandardError
      'unknown'
    end

    def get_proton_longest_time_on_same_port
      Service::Stats.new.get_proton_same_port
    rescue StandardError
      'unknown'
    end

    def get_opn_longest_time_on_same_port
      Service::Stats.new.get_opn_same_port
    rescue StandardError
      'unknown'
    end

    def get_qbit_longest_time_on_same_port
      Service::Stats.new.get_qbit_same_port
    rescue StandardError
      'unknown'
    end

    def get_proton_longest_time_on_same_port_to_s
      seconds_to_s(Service::Stats.new.get_proton_same_port)
    rescue StandardError
      'unknown'
    end

    def get_opn_longest_time_on_same_port_to_s
      seconds_to_s(Service::Stats.new.get_opn_same_port)
    rescue StandardError
      'unknown'
    end

    def get_qbit_longest_time_on_same_port_to_s
      seconds_to_s(Service::Stats.new.get_qbit_same_port)
    rescue StandardError
      'unknown'
    end
  end
end
