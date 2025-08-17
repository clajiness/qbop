module Framework
  # This class defines an API using the Grape framework.
  # It sets the response format to JSON and prefixes all routes with '/api'.
  class API < Grape::API
    format :json
    prefix :api

    get '/stats' do # rubocop:disable Metrics/BlockLength
      stats = Service::Stats.new.get_all
      helpers = Service::Helpers.new

      { 'stats' => {
          'protonvpn' => {
            'current_port': stats['proton_current_port'],
            'last_changed': stats['proton_updated_at'],
            'last_checked': stats['proton_last_checked'],
            'delta': helpers.time_delta(stats['proton_last_checked'], stats['proton_updated_at']),
            'connected': helpers.connected_to_service?(stats['proton_last_checked'])
          },
          'opnsense' => {
            'current_port': stats['opn_current_port'],
            'last_changed': stats['opn_updated_at'],
            'last_checked': stats['opn_last_checked'],
            'delta': helpers.time_delta(stats['opn_last_checked'], stats['opn_updated_at']),
            'connected': helpers.connected_to_service?(stats['opn_last_checked'])
          },
          'qbit' => {
            'current_port': stats['qbit_current_port'],
            'last_changed': stats['qbit_updated_at'],
            'last_checked': stats['qbit_last_checked'],
            'delta': helpers.time_delta(stats['qbit_last_checked'], stats['qbit_updated_at']),
            'connected': helpers.connected_to_service?(stats['qbit_last_checked'])
          }
        },
        'records' => {
          'longest_time_on_same_port' => {
            'proton': helpers.get_proton_longest_time_on_same_port,
            'opnsense': helpers.get_opn_longest_time_on_same_port,
            'qbit': helpers.get_qbit_longest_time_on_same_port
          }
        } }
    end

    get '/about' do
      helpers = Service::Helpers.new

      { 'about' => {
          app_version: ENV['VERSION'],
          app_uptime: helpers.job_uptime,
          schema_version: helpers.get_db_version,
          ruby_version: "#{RUBY_VERSION} (p#{RUBY_PATCHLEVEL})"
        },
        'env_variables' => {
          'ui_mode': ENV['UI_MODE'],
          'loop_freq': ENV['LOOP_FREQ'],
          'required_attempts': ENV['REQUIRED_ATTEMPTS'],
          'log_lines': ENV['LOG_LINES'],
          'proton_gateway': ENV['PROTON_GATEWAY'],
          'opn_skip': helpers.true?(ENV['OPN_SKIP']),
          'opn_interface_addr': ENV['OPN_INTERFACE_ADDR'],
          'opn_api_key': '***',
          'opn_api_secret': '***',
          'opn_proton_alias_name': ENV['OPN_PROTON_ALIAS_NAME'],
          'qbit_skip': helpers.true?(ENV['QBIT_SKIP']),
          'qbit_addr': ENV['QBIT_ADDR'],
          'qbit_user': ENV['QBIT_USER'],
          'qbit_pass': '***'
        } }
    end

    get '/notifications' do
      notification = Service::Notification.new.get_all

      { 'notifications' => {
        'update_available' => notification['update_available'],
        'update_version' => notification['update_version']
      } }
    end
  end
end
