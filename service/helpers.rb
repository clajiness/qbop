module Service
  # the Helpers class provides methods for setting environment variables and the script version
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
        qbit_skip: ENV['QBIT_SKIP'],
        qbit_addr: ENV['QBIT_ADDR'],
        qbit_user: ENV['QBIT_USER'],
        qbit_pass: ENV['QBIT_PASS']
      }
    end

    def parse_loop_frequency(loop_freq)
      loop_freq&.to_i if loop_freq&.to_i&.positive?
    end

    def skip_qbit?(qbit_skip)
      qbit_skip&.to_s&.downcase == 'true'
    end
  end
end
