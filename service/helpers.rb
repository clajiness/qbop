module Service
  # The Helpers class provides utility methods for accessing environment variables
  # and parsing specific configuration values used in the application.
  class Helpers
    def env_variables # rubocop:disable Metrics/MethodLength
      {
        script_version: ENV['VERSION'],
        loop_freq: ENV['LOOP_FREQ'] || 45,
        required_attempts: ENV['REQUIRED_ATTEMPTS'] || 3,
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

    def parse_loop_frequency(loop_freq)
      if loop_freq&.to_i&.positive?
        loop_freq&.to_i
      else
        45
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

      "#{dd}d, #{hh}h, #{mm}m, and #{ss}s"
    rescue StandardError
      'unknown'
    end

    def connected_to_service?(last_checked)
      Time.new(last_checked) > (Time.now - ((ENV['LOOP_FREQ'] || 45).to_i * 3))
    rescue StandardError
      false
    end
  end
end
