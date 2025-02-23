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

    def skip_qbit?(qbit_skip)
      qbit_skip&.to_s&.downcase == 'true'
    end

    def get_db_version
      user_version = 0

      SQLite3::Database.open 'data/prod.db' do |db|
        user_version = db.execute('pragma user_version;').flatten.first
      end

      user_version
    end
  end
end
