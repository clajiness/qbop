require_relative '../service/port_source'
require_relative 'authentication_config'
require_relative 'event_stream'
require_relative '../service/opnsense'
require_relative '../service/proton_wireguard'
require_relative '../service/proton_wireguard_rotation'
require_relative '../service/settings_presentation'
require_relative '../service/synchronization_configuration'

module Framework
  # The Web class is a Sinatra application that provides qbop's web UI routes.
  class Web < Sinatra::Application # rubocop:disable Metrics/ClassLength
    WIREGUARD_IMPORT_UNAVAILABLE = 'proton wireguard import requires opnsense integration.'.freeze
    SETTINGS_VALUE_UNAVAILABLE = Object.new.freeze
    private_constant :SETTINGS_VALUE_UNAVAILABLE

    before do
      headers 'Cache-Control' => 'no-store' if settings_request?
      unless public_asset_request? || public_authentication_request? || !web_auth_enabled?
        authentication = request.env.fetch('rodauth')
        DB[:accounts].count.zero? ? redirect('/setup') : authentication.require_authentication
      end

      if request.post? && csrf_mutation_request?
        authentication = request.env.fetch('rodauth')
        halt 403 unless authentication.scope.valid_csrf?
      end

      headers 'Cache-Control' => 'no-store' if api_keys_request? || tools_request?

      update = Notification.select(:info, :active).where(name: 'update_available').first
      @recent_tag = update&.info
      @update_available = Service::Helpers.new.release_build? && (update&.active || false)
    end

    get '/' do
      @live_updates = true
      load_status
      erb :index
    end

    get '/partials/status' do
      headers 'Cache-Control' => 'no-store'
      load_status
      erb :_status, layout: false
    end

    get '/events' do
      content_type 'text/event-stream'
      headers 'Cache-Control' => 'no-cache', 'X-Accel-Buffering' => 'no'
      halt 200 if request.head?

      subscriber = Events.subscribe
      halt 503, { 'Retry-After' => '3' }, 'Live updates are busy; reconnect shortly.' unless subscriber

      body EventStream.new(subscriber)
    end

    get '/api-docs' do
      erb :api_docs
    end

    get '/api-keys' do
      @new_api_key = request.session.delete(:new_api_key)
      @api_key_error = request.session.delete(:api_key_error)
      @api_keys = ApiKey.reverse_order(:created_at, :id).all

      erb :api_keys
    end

    get '/settings' do
      @settings_page = true
      @settings_notice = request.session.delete(:settings_notice)
      @settings_error = request.session.delete(:settings_error)
      @settings_sections = settings_presentation.sections

      erb :settings
    end

    post '/settings/:key' do
      entry = settings_entry
      if entry.environment_override?
        request.session[:settings_error] = "#{entry.label} is managed by environment and cannot be edited here."
      else
        changed = settings_effective_value_changed?(entry) { settings_service.set(entry.key, params['value']) }
        request.session[:settings_notice] = settings_success_message(entry, 'saved', changed: changed)
      end
      redirect '/settings', 303
    rescue Service::Settings::ValidationError => e
      request.session[:settings_error] = e.message
      redirect '/settings', 303
    rescue Service::Settings::ConfigurationError
      request.session[:settings_error] = 'Credential could not be saved. Check the qbop configuration and try again.'
      redirect '/settings', 303
    end

    post '/settings/:key/delete' do
      entry = settings_entry
      halt 404, 'No qbop override is stored for this setting.' unless entry.database_value_present?

      changed = settings_effective_value_changed?(entry) { settings_service.delete(entry.key) }
      request.session[:settings_notice] = settings_success_message(entry, 'cleared', changed: changed)
      redirect '/settings', 303
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

    post '/api-keys' do
      issued_key = ApiKey.issue(params['name'])
      request.session[:new_api_key] = issued_key.token
      redirect '/api-keys', 303
    rescue ApiKey::InvalidName => e
      request.session[:api_key_error] = e.message
      redirect '/api-keys', 303
    end

    post '/api-keys/:id/delete' do
      halt 404 unless params['id'].match?(/\A[1-9][0-9]*\z/)

      api_key = ApiKey[params['id'].to_i]
      halt 404 unless api_key

      api_key.delete
      redirect '/api-keys', 303
    end

    get '/tools' do
      load_wireguard_targets
      erb :tools
    end

    post '/wireguard-import' do # rubocop:disable Metrics/BlockLength
      if opnsense_skipped?
        load_wireguard_targets
      else
        begin
          @wireguard_instance_uuid = params['wireguardinstance'].to_s.strip
          @wireguard_peer_uuid = params['wireguardpeer'].to_s.strip
          config_text = wireguard_config_input(params['wireguardconfig']&.to_s)
          wireguard = Service::ProtonWireguard.new.import(config_text)
          result = Service::ProtonWireguardRotation.new(
            Service::Helpers.new.wireguard_config
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
      end

      erb :tools
    end

    post '/pubkey' do
      helpers = Service::Helpers.new

      @public_key = helpers.generate_wg_public_key(params['privatekey']&.strip)

      initialize_unloaded_wireguard_targets
      erb :tools
    end

    post '/public-ip' do
      helpers = Service::Helpers.new

      service = helpers.public_ip_provider(params['select'])
      @public_ip = service ? "#{service} -> #{helpers.get_public_ip(service)}" : 'unknown provider'

      initialize_unloaded_wireguard_targets
      erb :tools
    end

    get '/logs' do
      @live_updates = true
      load_logs
      erb :logs
    end

    get '/partials/logs' do
      headers 'Cache-Control' => 'no-store'
      load_logs
      erb :_logs, layout: false
    end

    get '/history' do
      @live_updates = true
      load_history
      erb :history
    end

    get '/partials/history' do
      headers 'Cache-Control' => 'no-store'
      load_history
      erb :_history, layout: false
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

      @ui_mode = settings_service.value(:ui_mode)
      @loop_freq = settings_service.value(:loop_freq)
      @required_attempts = settings_service.value(:required_attempts)
      @log_lines = helpers.validate_log_lines(nil)
      @log_reverse = helpers.true?(settings_service.value(:log_reverse))
      @log_to_stdout = helpers.true?(settings_service.value(:log_to_stdout))
      @port_source_name = Service::PortSource.name(port_source: settings_service.value(:port_source))
      @gluetun_addr = helpers.redact_url_credentials(settings_service.value(:gluetun_addr))
      @gluetun_ssl_verify = settings_service.value(:gluetun_ssl_verify)
      @proton_gateway = settings_service.value(:proton_gateway)
      @opn_skip = helpers.true?(settings_service.value(:opnsense_skip))
      @opn_interface_addr = settings_service.value(:opnsense_interface_addr)
      @opn_api_key = '***'
      @opn_api_secret = '***'
      @opn_alias_name = settings_service.value(:opnsense_alias_name)
      @opn_proton_alias_name = ENV['OPN_PROTON_ALIAS_NAME']
      @opn_ssl_verify = settings_service.value(:opnsense_ssl_verify)
      @qbit_skip = helpers.true?(settings_service.value(:qbit_skip))
      @qbit_addr = settings_service.value(:qbit_addr)
      @qbit_api_key = '***'
      @qbit_user = ENV['QBIT_USER']
      @qbit_pass = '***'
      @qbit_ssl_verify = settings_service.value(:qbit_ssl_verify)
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

    def settings_service
      @settings_service ||= Service::Settings.new
    end

    def settings_presentation
      @settings_presentation ||= Service::SettingsPresentation.new(settings: settings_service)
    end

    def settings_entry
      settings_presentation.find(params['key']) || halt(404, 'Setting not found.')
    end

    def settings_effective_value_changed?(entry)
      previous = settings_effective_value(entry)
      yield
      current = settings_effective_value(entry)
      previous.equal?(SETTINGS_VALUE_UNAVAILABLE) || current.equal?(SETTINGS_VALUE_UNAVAILABLE) || previous != current
    end

    def settings_effective_value(entry)
      value = settings_service.value(entry.key)
      entry.metadata.input_type == :boolean ? Service::Helpers.new.true?(value) : value
    rescue Service::Settings::ConfigurationError
      # Unreadable existing credentials must still be replaceable or clearable.
      SETTINGS_VALUE_UNAVAILABLE
    end

    def settings_success_message(entry, action, changed:)
      message = "#{entry.label} #{action}."
      return message unless entry.restart_required? && changed

      "#{message} Restart qbop to apply this change to the running synchronization job."
    end

    def settings_request?
      request.path_info == '/settings' || request.path_info.start_with?('/settings/')
    end

    def load_status # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      helpers = Service::Helpers.new
      stats = Stat.by_source_name

      config = Service::SynchronizationConfiguration.current(settings_service)
      configured = Service::SynchronizationConfiguration.resolve(settings_service)
      @synchronization_restart_required = config.source_or_skip_changed?(configured)
      @configured_port_source = configured.port_source
      @port_source_name = config.port_source
      @port_stats = stats[@port_source_name] || Stat::Snapshot.new(
        source_id: nil, source_name: @port_source_name, current_port: nil, same_port: 0,
        updated_at: nil, last_checked: nil
      )
      @opn_stats = stats['opnsense']
      @qbit_stats = stats['qbit']

      @port_connected = helpers.connected_to_service?(@port_stats.last_checked, loop_frequency: config.loop_freq)
      @opn_connected = helpers.connected_to_service?(@opn_stats.last_checked, loop_frequency: config.loop_freq)
      @qbit_connected = helpers.connected_to_service?(@qbit_stats.last_checked, loop_frequency: config.loop_freq)

      @port_delta = helpers.time_delta_to_s(@port_stats.last_checked, @port_stats.updated_at)
      @opn_delta = helpers.time_delta_to_s(@opn_stats.last_checked, @opn_stats.updated_at)
      @qbit_delta = helpers.time_delta_to_s(@qbit_stats.last_checked, @qbit_stats.updated_at)

      @opn_skip = config.opnsense_skip
      @qbit_skip = config.qbit_skip

      @port_longest_time_on_same_port = helpers.seconds_to_s(@port_stats.same_port)
      @opn_longest_time_on_same_port = helpers.seconds_to_s(@opn_stats.same_port)
      @qbit_longest_time_on_same_port = helpers.seconds_to_s(@qbit_stats.same_port)

      @transition = PortTransition.where(new_port: @port_stats.current_port,
                                         source_name: @port_source_name).order(Sequel.desc(:id)).first
      @opn_sync_status = if Source[name: 'opnsense'].counter&.pending_apply_port
                           'pending'
                         else
                           @transition&.sync_status('opnsense')
                         end
    end

    def load_logs
      helpers = Service::Helpers.new

      @log_lines = helpers.validate_log_lines(params['lines'])
      @log_direction = helpers.format_log_direction(
        params['direction'], default_reverse: helpers.true?(settings_service.value(:log_reverse))
      )
      log_reverse = @log_direction == 'desc'
      @output = helpers.log_lines_to_a(@log_lines, log_reverse)
    end

    def load_history
      helpers = Service::Helpers.new
      page = helpers.validate_page(params['page'])
      per_page = helpers.validate_history_page_size(params['per_page'])

      @pagination = PortTransition.paginate(page: page, per_page: per_page)
    end

    def public_asset_request?
      request.path_info.start_with?('/css/', '/images/', '/js/')
    end

    def public_authentication_request?
      [AuthenticationConfig::OIDC_FAILURE_PATH, AuthenticationConfig::LOGGED_OUT_PATH].include?(request.path_info)
    end

    def api_keys_request?
      request.path_info == '/api-keys' || request.path_info.start_with?('/api-keys/')
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
      @wireguard_targets = { instances: [], peers: [] }
      if opnsense_skipped?
        @wireguard_import_unavailable = WIREGUARD_IMPORT_UNAVAILABLE
        return
      end

      @wireguard_targets = Service::Opnsense.new(Service::Helpers.new.wireguard_config).wireguard_targets
    rescue Service::Opnsense::WireguardImportError => e
      @wireguard_targets_error = e.message
    end

    def initialize_unloaded_wireguard_targets
      @wireguard_targets = { instances: [], peers: [] }
      if opnsense_skipped?
        @wireguard_import_unavailable = WIREGUARD_IMPORT_UNAVAILABLE
      else
        @wireguard_targets_not_loaded = true
      end
    end

    def opnsense_skipped?
      Service::Helpers.new.true?(settings_service.value(:opnsense_skip))
    end

    def csrf_mutation_request?
      request.path_info == '/wireguard-import' || api_key_mutation_request? || settings_request?
    end

    def api_key_mutation_request?
      request.path_info == '/api-keys' || request.path_info.start_with?('/api-keys/')
    end

    def web_auth_enabled?
      authentication_config.web_auth_enabled?
    end

    def authentication_config
      request.env.fetch('qbop.auth_config')
    end
  end
end
