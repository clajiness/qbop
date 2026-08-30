require_relative 'authentication_config'
require_relative '../service/opnsense'
require_relative '../service/proton_wireguard'
require_relative '../service/proton_wireguard_rotation'

module Framework
  # The Web class is a Sinatra application that provides qbop's web UI routes.
  class Web < Sinatra::Application # rubocop:disable Metrics/ClassLength
    before do
      unless public_asset_request? || public_authentication_request? || !web_auth_enabled?
        authentication = request.env.fetch('rodauth')
        DB[:accounts].count.zero? ? redirect('/setup') : authentication.require_authentication
      end

      if request.post? && csrf_mutation_request?
        authentication = request.env.fetch('rodauth')
        halt 403 unless authentication.scope.valid_csrf?
      end

      headers 'Cache-Control' => 'no-store' if api_docs_request? || tools_request?

      update = Notification.select(:info, :active).where(name: 'update_available').first
      @recent_tag = update&.info
      @update_available = Service::Helpers.new.release_build? && (update&.active || false)
    end

    get '/' do
      helpers = Service::Helpers.new
      stats = Stat.by_source_name

      @refresh_seconds = helpers.validate_refresh_interval(params['refresh'])

      @proton_stats = stats['proton']
      @opn_stats = stats['opnsense']
      @qbit_stats = stats['qbit']

      @proton_connected = helpers.connected_to_service?(@proton_stats.last_checked)
      @opn_connected = helpers.connected_to_service?(@opn_stats.last_checked)
      @qbit_connected = helpers.connected_to_service?(@qbit_stats.last_checked)

      @proton_delta = helpers.time_delta_to_s(@proton_stats.last_checked, @proton_stats.updated_at)
      @opn_delta = helpers.time_delta_to_s(@opn_stats.last_checked, @opn_stats.updated_at)
      @qbit_delta = helpers.time_delta_to_s(@qbit_stats.last_checked, @qbit_stats.updated_at)

      @opn_skip = helpers.true?(ENV['OPN_SKIP'])
      @qbit_skip = helpers.true?(ENV['QBIT_SKIP'])

      @proton_longest_time_on_same_port = helpers.seconds_to_s(@proton_stats.same_port)
      @opn_longest_time_on_same_port = helpers.seconds_to_s(@opn_stats.same_port)
      @qbit_longest_time_on_same_port = helpers.seconds_to_s(@qbit_stats.same_port)

      erb :index
    end

    get '/api-docs' do
      @new_api_key = request.session.delete(:new_api_key)
      @api_key_error = request.session.delete(:api_key_error)
      @api_keys = ApiKey.reverse_order(:created_at, :id).all

      erb :api_docs
    end

    get '/account' do
      halt 404 unless web_auth_enabled?

      authentication = request.env.fetch('rodauth')
      @account_email = authentication.account!.fetch(:email)
      notice = authentication.flash.delete(authentication.flash_notice_key)
      account_notices = [authentication.change_login_notice_flash, authentication.change_password_notice_flash]
      @account_notice = notice if account_notices.include?(notice)
      @account_error = authentication.flash.delete(authentication.flash_error_key)

      erb :account
    end

    get '/oidc/error' do
      halt 404 unless authentication_config.oidc_active?

      authentication = request.env.fetch('rodauth')
      @oidc_error = authentication.flash.delete(authentication.flash_error_key)
      @oidc_error ||= Framework::Authentication::OIDC_FAILURE_MESSAGE
      @auth_config = authentication_config

      erb :oidc_error
    end

    get '/logged-out' do
      halt 404 unless authentication_config.oidc_active?

      erb :logged_out
    end

    post '/api-docs/keys' do
      issued_key = ApiKey.issue(params['name'])
      request.session[:new_api_key] = issued_key.token
      redirect '/api-docs', 303
    rescue ApiKey::InvalidName => e
      request.session[:api_key_error] = e.message
      redirect '/api-docs', 303
    end

    post '/api-docs/keys/:id/delete' do
      halt 404 unless params['id'].match?(/\A[1-9][0-9]*\z/)

      api_key = ApiKey[params['id'].to_i]
      halt 404 unless api_key

      api_key.delete
      redirect '/api-docs', 303
    end

    get '/tools' do
      load_wireguard_targets
      erb :tools
    end

    post '/wireguard-import' do
      begin
        @wireguard_instance_uuid = params['wireguardinstance'].to_s.strip
        @wireguard_peer_uuid = params['wireguardpeer'].to_s.strip
        config_text = wireguard_config_input(params['wireguardconfig']&.to_s)
        wireguard = Service::ProtonWireguard.new.import(config_text)
        result = Service::ProtonWireguardRotation.new(
          Service::Helpers.new.env_variables
        ).rotate(
          wireguard,
          instance_uuid: @wireguard_instance_uuid,
          peer_uuid: @wireguard_peer_uuid,
          rename_peer: Service::Helpers.new.true?(params['wireguardrenamepeer'])
        )
        @wireguard_result = "updated instance #{result[:instance_name]} and peer #{result[:peer_name]}"
      rescue Service::ProtonWireguardRotation::Busy => e
        status 409
        @wireguard_error = e.message
      rescue Service::ProtonWireguard::ImportError, Service::ProtonWireguardRotation::Error => e
        @wireguard_error = e.message
      ensure
        load_wireguard_targets
      end

      erb :tools
    end

    post '/pubkey' do
      helpers = Service::Helpers.new

      @public_key = helpers.generate_wg_public_key(params['privatekey']&.strip)

      load_wireguard_targets
      erb :tools
    end

    post '/public-ip' do
      helpers = Service::Helpers.new

      service = params['select']&.strip&.downcase
      public_ip = helpers.get_public_ip(service)

      @public_ip = "#{service} -> #{public_ip}"

      load_wireguard_targets
      erb :tools
    end

    get '/logs' do
      helpers = Service::Helpers.new

      @refresh_seconds = helpers.validate_refresh_interval(params['refresh'])
      @log_lines = helpers.validate_log_lines(params['lines'])
      @log_direction = helpers.format_log_direction(
        params['direction'], default_reverse: helpers.true?(helpers.env_variables[:log_reverse])
      )
      log_reverse = @log_direction == 'desc'
      @output = helpers.log_lines_to_a(@log_lines, log_reverse)

      erb :logs
    end

    get '/history' do
      helpers = Service::Helpers.new
      @refresh_seconds = helpers.validate_refresh_interval(params['refresh'])
      page = helpers.validate_page(params['page'])
      per_page = helpers.validate_history_page_size(params['per_page'])

      @pagination = PortTransition.paginate(page: page, per_page: per_page)

      erb :history
    end

    get '/about' do # rubocop:disable Metrics/BlockLength
      helpers = Service::Helpers.new

      @app_version = helpers.app_version
      @app_commit = helpers.commit_sha
      @short_app_commit = helpers.short_commit_sha
      @build_date = helpers.build_date
      @release_build = helpers.release_build?
      @main_build = helpers.main_build?
      @schema_version = helpers.get_db_version
      @ruby_version = "#{RUBY_VERSION} (p#{RUBY_PATCHLEVEL})"
      @uptime = helpers.seconds_to_s(Framework::Uptime.uptime_seconds)
      @start_time = Framework::Uptime.started_at
      @repo_url = 'https://github.com/clajiness/qbop'

      @ui_mode = ENV['UI_MODE']
      @loop_freq = ENV['LOOP_FREQ']
      @required_attempts = ENV['REQUIRED_ATTEMPTS']
      @log_lines = ENV['LOG_LINES']
      @log_reverse = helpers.true?(ENV['LOG_REVERSE'])
      @log_to_stdout = helpers.true?(ENV['LOG_TO_STDOUT'])
      @proton_gateway = ENV['PROTON_GATEWAY']
      @opn_skip = helpers.true?(ENV['OPN_SKIP'])
      @opn_interface_addr = ENV['OPN_INTERFACE_ADDR']
      @opn_api_key = '***'
      @opn_api_secret = '***'
      @opn_proton_alias_name = ENV['OPN_PROTON_ALIAS_NAME']
      @opn_ssl_verify = helpers.true?(ENV['OPN_SSL_VERIFY'])
      @qbit_skip = helpers.true?(ENV['QBIT_SKIP'])
      @qbit_addr = ENV['QBIT_ADDR']
      @qbit_api_key = '***'
      @qbit_user = ENV['QBIT_USER']
      @qbit_pass = '***'
      @qbit_ssl_verify = helpers.true?(ENV['QBIT_SSL_VERIFY'])
      auth_config = authentication_config
      @web_auth_enabled = auth_config.web_auth_enabled?
      @oidc_enabled = auth_config.oidc_enabled?
      @oidc_issuer = auth_config.oidc_issuer
      @oidc_client_id = auth_config.oidc_client_id
      @oidc_client_secret = '***'
      @oidc_public_url = auth_config.oidc_public_url
      @oidc_auto_redirect = auth_config.oidc_auto_redirect?
      @local_login_enabled = auth_config.local_login_enabled?

      @gemfile = helpers.gemfile_to_a

      erb :about
    end

    private

    def public_asset_request?
      request.path_info.start_with?('/css/', '/images/')
    end

    def public_authentication_request?
      [AuthenticationConfig::OIDC_FAILURE_PATH, AuthenticationConfig::LOGGED_OUT_PATH].include?(request.path_info)
    end

    def api_docs_request?
      request.path_info == '/api-docs' || request.path_info.start_with?('/api-docs/')
    end

    def tools_request?
      ['/tools', '/wireguard-import', '/pubkey', '/public-ip'].include?(request.path_info)
    end

    def wireguard_config_input(pasted_config)
      upload = params['wireguardfile']
      if upload.is_a?(Hash)
        tempfile = upload[:tempfile] || upload['tempfile']
        if tempfile.respond_to?(:read)
          tempfile.rewind if tempfile.respond_to?(:rewind)
          return tempfile.read(Service::ProtonWireguard::MAX_CONFIG_BYTES + 1)
        end
      end

      pasted_config
    end

    def load_wireguard_targets
      @wireguard_targets = Service::Opnsense.new(Service::Helpers.new.env_variables).wireguard_targets
    rescue Service::Opnsense::WireguardImportError => e
      @wireguard_targets = { instances: [], peers: [] }
      @wireguard_targets_error = e.message
    end

    def csrf_mutation_request?
      request.path_info == '/wireguard-import' || api_key_mutation_request?
    end

    def api_key_mutation_request?
      request.path_info == '/api-docs/keys' || request.path_info.start_with?('/api-docs/keys/')
    end

    def web_auth_enabled?
      authentication_config.web_auth_enabled?
    end

    def authentication_config
      request.env.fetch('qbop.auth_config')
    end
  end
end
