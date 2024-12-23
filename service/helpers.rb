module Service
  # the Helpers class provides methods for setting environment variables and the script version
  class Helpers
    def initialize
      @env_variables = env_variables
      @version = version
    end

    def env_variables # rubocop:disable Metrics/MethodLength
      {
        loop_freq: ENV['LOOP_FREQ'] || 45,
        proton_gateway: ENV['PROTON_GATEWAY'],
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

    def version
      return unless File.exist?('version.yml')

      YAML.safe_load(File.read('version.yml'))['version']
    end
  end
end
