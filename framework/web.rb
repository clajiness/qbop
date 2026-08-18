module Framework
  # The Web class is a Sinatra application that provides qbop's web UI routes.
  class Web < Sinatra::Application # rubocop:disable Metrics/ClassLength
    before do
      unless public_asset_request? || !web_auth_enabled?
        authentication = request.env.fetch('rodauth')
        DB[:accounts].count.zero? ? redirect('/setup') : authentication.require_authentication
      end

      if request.post? && api_key_mutation_request?
        authentication = request.env.fetch('rodauth')
        halt 403 unless authentication.scope.valid_csrf?
      end

      headers 'Cache-Control' => 'no-store' if api_docs_request?

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
      erb :tools
    end

    post '/pubkey' do
      helpers = Service::Helpers.new

      @public_key = helpers.generate_wg_public_key(params['privatekey']&.strip)

      erb :tools
    end

    post '/public-ip' do
      helpers = Service::Helpers.new

      service = params['select']&.strip&.downcase
      public_ip = helpers.get_public_ip(service)

      @public_ip = "#{service} -> #{public_ip}"

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
      @web_auth_enabled = helpers.true?(helpers.env_variables[:web_auth_enabled])

      @gemfile = helpers.gemfile_to_a

      erb :about
    end

    private

    def public_asset_request?
      request.path_info.start_with?('/css/', '/images/')
    end

    def api_docs_request?
      request.path_info == '/api-docs' || request.path_info.start_with?('/api-docs/')
    end

    def api_key_mutation_request?
      request.path_info == '/api-docs/keys' || request.path_info.start_with?('/api-docs/keys/')
    end

    def web_auth_enabled?
      helpers = Service::Helpers.new
      helpers.true?(helpers.env_variables[:web_auth_enabled])
    end
  end
end
