require_relative '../service/opnsense'
require_relative '../service/proton_wireguard'
require_relative '../service/proton_wireguard_rotation'

module Framework
  # This class defines an API using the Grape framework.
  # It sets the response format to JSON and prefixes all routes with '/api'.
  class API < Grape::API # rubocop:disable Metrics/ClassLength
    format :json
    prefix :api

    helpers do
      def authenticate_api_key!
        authorization = headers['Authorization']
        token = authorization&.match(/\ABearer[ \t]+(\S+)\z/i)&.captures&.first
        return if ApiKey.authenticate(token)

        error!({ 'error' => 'unauthorized' }, 401, 'WWW-Authenticate' => 'Bearer realm="qbop"')
      end
    end

    before { authenticate_api_key! }

    get '/stats' do # rubocop:disable Metrics/BlockLength
      helpers = Service::Helpers.new
      stats = Stat.by_source_name

      @proton_stats = stats['proton']
      @opn_stats = stats['opnsense']
      @qbit_stats = stats['qbit']

      { 'stats' => {
          'protonvpn' => {
            'current_port': @proton_stats.current_port,
            'last_changed': @proton_stats.updated_at,
            'last_checked': @proton_stats.last_checked,
            'delta': helpers.time_delta(@proton_stats.last_checked, @proton_stats.updated_at),
            'connected': helpers.connected_to_service?(@proton_stats.last_checked)
          },
          'opnsense' => {
            'current_port': @opn_stats.current_port,
            'last_changed': @opn_stats.updated_at,
            'last_checked': @opn_stats.last_checked,
            'delta': helpers.time_delta(@opn_stats.last_checked, @opn_stats.updated_at),
            'connected': helpers.connected_to_service?(@opn_stats.last_checked)
          },
          'qbit' => {
            'current_port': @qbit_stats.current_port,
            'last_changed': @qbit_stats.updated_at,
            'last_checked': @qbit_stats.last_checked,
            'delta': helpers.time_delta(@qbit_stats.last_checked, @qbit_stats.updated_at),
            'connected': helpers.connected_to_service?(@qbit_stats.last_checked)
          }
        },
        'records' => {
          'longest_time_on_same_port' => {
            'proton': @proton_stats.same_port,
            'opnsense': @opn_stats.same_port,
            'qbit': @qbit_stats.same_port
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

    get '/tools/wireguard-targets' do
      targets = Service::Opnsense.new(Service::Helpers.new.env_variables).wireguard_targets

      { 'wireguard_targets' => targets }
    rescue Service::Opnsense::WireguardImportError => e
      error!({ 'error' => e.message }, 422)
    end

    post '/tools/wireguard-import' do
      wireguard = Service::ProtonWireguard.new.import(params['config'])
      result = Service::ProtonWireguardRotation.new(
        Service::Helpers.new.env_variables
      ).rotate(
        wireguard,
        instance_uuid: params['instance_uuid'].to_s.strip,
        peer_uuid: params['peer_uuid'].to_s.strip
      )

      status 200
      { 'wireguard_import' => result }
    rescue Service::ProtonWireguardRotation::Busy => e
      error!({ 'error' => e.message }, 409)
    rescue Service::ProtonWireguard::ImportError, Service::ProtonWireguardRotation::Error => e
      error!({ 'error' => e.message }, 422)
    end

    get '/tools/public-ip' do
      helpers = Service::Helpers.new
      service = params['service']&.strip&.downcase
      public_ip = helpers.get_public_ip(service)&.strip

      if public_ip == 'unknown provider'
        {
          'service' => service,
          'public_ip' => 'Unknown provider - Please use Akamai, Cloudflare, Google, or OpenDNS'
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

      log_line_count = helpers.validate_log_lines(params['lines'])
      log_direction = helpers.format_log_direction(
        params['direction'],
        default_reverse: helpers.true?(helpers.env_variables[:log_reverse])
      )
      log_lines = helpers.log_lines_to_a(log_line_count, log_direction == 'desc')

      { 'log_lines' => log_lines.map(&:strip) }
    end

    get '/history' do # rubocop:disable Metrics/BlockLength
      helpers = Service::Helpers.new
      page = helpers.validate_page(params['page'])
      per_page = helpers.validate_history_page_size(params['per_page'])
      pagination = PortTransition.paginate(page: page, per_page: per_page)

      history = pagination.records.map do |transition|
        {
          'id' => transition.id,
          'previous_port' => transition.previous_port,
          'new_port' => transition.new_port,
          'detected_at' => transition.detected_at,
          'opnsense' => {
            'status' => transition.sync_status('opnsense'),
            'synced_at' => transition.opnsense_synced_at
          },
          'qbit' => {
            'status' => transition.sync_status('qbit'),
            'synced_at' => transition.qbit_synced_at
          }
        }
      end

      { 'history' => history,
        'pagination' => {
          'total_records' => pagination.total_records,
          'current_page' => pagination.current_page,
          'per_page' => pagination.per_page,
          'total_pages' => pagination.total_pages,
          'from' => pagination.from,
          'to' => pagination.to
        } }
    end

    get '/about' do # rubocop:disable Metrics/BlockLength
      helpers = Service::Helpers.new

      { 'about' => {
          app_version: helpers.app_version,
          commit_sha: helpers.commit_sha,
          build_date: helpers.build_date,
          schema_version: helpers.get_db_version,
          ruby_version: "#{RUBY_VERSION} (p#{RUBY_PATCHLEVEL})",
          start_time: Framework::Uptime.started_at,
          uptime: Framework::Uptime.uptime_seconds.to_i
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
          'opn_ssl_verify': helpers.true?(ENV['OPN_SSL_VERIFY']),
          'qbit_skip': helpers.true?(ENV['QBIT_SKIP']),
          'qbit_addr': ENV['QBIT_ADDR'],
          'qbit_api_key': '***',
          'qbit_user': ENV['QBIT_USER'],
          'qbit_pass': '***',
          'qbit_ssl_verify': helpers.true?(ENV['QBIT_SSL_VERIFY'])
        } }
    end

    get '/health' do
      helpers = Service::Helpers.new
      stats = Stat.by_source_name

      @proton_stats = stats['proton']
      @opn_stats = stats['opnsense']
      @qbit_stats = stats['qbit']
      service_status = ->(source_stats) { helpers.connected_to_service?(source_stats.last_checked) ? 200 : 503 }

      health = {
        'protonvpn' => service_status.call(@proton_stats),
        'opnsense' => helpers.true?(ENV['OPN_SKIP']) ? 'skipped' : service_status.call(@opn_stats),
        'qbit' => helpers.true?(ENV['QBIT_SKIP']) ? 'skipped' : service_status.call(@qbit_stats)
      }

      status health.value?(503) ? 503 : 200

      { 'health' => health }
    end

    get '/notifications' do
      notification = Notification[name: 'update_available']

      { 'notifications' => {
        'name' => 'update_available',
        'info' => notification&.info,
        'active' => notification&.active || false
      } }
    end
  end
end
