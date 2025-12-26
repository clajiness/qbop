module Framework
  # This class defines an API using the Grape framework.
  # It sets the response format to JSON and prefixes all routes with '/api'.
  class API < Grape::API # rubocop:disable Metrics/ClassLength
    format :json
    prefix :api

    get '/stats' do # rubocop:disable Metrics/BlockLength
      helpers = Service::Helpers.new
      stats = Stat.as_hash

      @proton_stats = stats[1]
      @opn_stats = stats[2]
      @qbit_stats = stats[3]

      { 'stats' => {
          'protonvpn' => {
            'current_port': @proton_stats[:current_port],
            'last_changed': @proton_stats[:updated_at],
            'last_checked': @proton_stats[:last_checked],
            'delta': helpers.time_delta(@proton_stats[:last_checked], @proton_stats[:updated_at]),
            'connected': helpers.connected_to_service?(@proton_stats[:last_checked])
          },
          'opnsense' => {
            'current_port': @opn_stats[:current_port],
            'last_changed': @opn_stats[:updated_at],
            'last_checked': @opn_stats[:last_checked],
            'delta': helpers.time_delta(@opn_stats[:last_checked], @opn_stats[:updated_at]),
            'connected': helpers.connected_to_service?(@opn_stats[:last_checked])
          },
          'qbit' => {
            'current_port': @qbit_stats[:current_port],
            'last_changed': @qbit_stats[:updated_at],
            'last_checked': @qbit_stats[:last_checked],
            'delta': helpers.time_delta(@qbit_stats[:last_checked], @qbit_stats[:updated_at]),
            'connected': helpers.connected_to_service?(@qbit_stats[:last_checked])
          }
        },
        'records' => {
          'longest_time_on_same_port' => {
            'proton': @proton_stats[:same_port],
            'opnsense': @opn_stats[:same_port],
            'qbit': @qbit_stats[:same_port]
          }
        } }
    end

    get '/tools/pubkey' do
      helpers = Service::Helpers.new

      public_key = helpers.generate_wg_public_key(params['private-key']&.strip)

      {
        'public_key' => public_key
      }
    end

    get '/tools/public-ip' do
      helpers = Service::Helpers.new
      service = params['service']&.strip&.downcase&.shellescape
      public_ip = helpers.get_public_ip(service)&.strip

      if public_ip == 'unknown provider'
        {
          'service' => service,
          'public_ip' => 'Unknown service - Please use Akamai, Cloudflare, Google, or OpenDNS'
        }
      else
        {
          'service' => service,
          'public_ip' => public_ip
        }
      end
    end

    get '/logs' do
      helpers = Service::Helpers.new

      log_lines = helpers.log_lines_to_a(ENV['LOG_LINES'] || 100)

      { 'log_lines' => log_lines.map(&:strip) }
    end

    get '/about' do # rubocop:disable Metrics/BlockLength
      helpers = Service::Helpers.new

      { 'about' => {
          app_version: ENV['VERSION'],
          schema_version: helpers.get_db_version,
          ruby_version: "#{RUBY_VERSION} (p#{RUBY_PATCHLEVEL})"
        },
        'env_variables' => {
          'ui_mode': ENV['UI_MODE'],
          'loop_freq': ENV['LOOP_FREQ'],
          'required_attempts': ENV['REQUIRED_ATTEMPTS'],
          'log_lines': ENV['LOG_LINES'],
          'log_reverse': helpers.true?(ENV['LOG_REVERSE']),
          'log_to_stdout': helpers.true?(ENV['LOG_TO_STDOUT']),
          'proton_gateway': ENV['PROTON_GATEWAY'],
          'opn_skip': helpers.true?(ENV['OPN_SKIP']),
          'opn_interface_addr': ENV['OPN_INTERFACE_ADDR'],
          'opn_api_key': '***',
          'opn_api_secret': '***',
          'opn_proton_alias_name': ENV['OPN_PROTON_ALIAS_NAME'],
          'qbit_skip': helpers.true?(ENV['QBIT_SKIP']),
          'qbit_addr': ENV['QBIT_ADDR'],
          'qbit_user': ENV['QBIT_USER'],
          'qbit_pass': '***',
          'basic_auth_enabled': helpers.true?(ENV['BASIC_AUTH_ENABLED']),
          'basic_auth_user': ENV['BASIC_AUTH_USER'],
          'basic_auth_pass': '***'
        } }
    end

    get '/health' do
      helpers = Service::Helpers.new
      stats = Stat.as_hash

      @proton_stats = stats[1]
      @opn_stats = stats[2]
      @qbit_stats = stats[3]

      { 'health' => {
        'protonvpn': helpers.connected_to_service?(@proton_stats[:last_checked]) ? (status 200) : (status 503),
        'opnsense': helpers.connected_to_service?(@opn_stats[:last_checked]) ? (status 200) : (status 503),
        'qbit': helpers.connected_to_service?(@qbit_stats[:last_checked]) ? (status 200) : (status 503)
      } }
    end

    get '/notifications' do
      notifications = Notification.as_hash

      { 'notifications' => {
        'name' => notifications[1][:name],
        'info' => notifications[1][:info],
        'active' => notifications[1][:active]
      } }
    end
  end
end
