module Framework
  # The Web class is a Sinatra application that provides three routes
  # for displaying statistics, logs, and about information.
  class Web < Sinatra::Application
    get '/' do
      helpers = Service::Helpers.new
      stats = Stat.as_hash

      update = Notification.select(:info, :active).where(name: 'update_available').first
      @recent_tag = update[:info]
      @update_available = update[:active]

      @proton_stats = stats[1]
      @opn_stats = stats[2]
      @qbit_stats = stats[3]

      @proton_connected = helpers.connected_to_service?(@proton_stats[:last_checked])
      @opn_connected = helpers.connected_to_service?(@opn_stats[:last_checked])
      @qbit_connected = helpers.connected_to_service?(@qbit_stats[:last_checked])

      @proton_delta = helpers.time_delta_to_s(@proton_stats[:last_checked], @proton_stats[:updated_at])
      @opn_delta = helpers.time_delta_to_s(@opn_stats[:last_checked], @opn_stats[:updated_at])
      @qbit_delta = helpers.time_delta_to_s(@qbit_stats[:last_checked], @qbit_stats[:updated_at])

      @opn_skip = helpers.true?(ENV['OPN_SKIP'])
      @qbit_skip = helpers.true?(ENV['QBIT_SKIP'])

      @proton_longest_time_on_same_port = helpers.seconds_to_s(@proton_stats[:same_port])
      @opn_longest_time_on_same_port = helpers.seconds_to_s(@opn_stats[:same_port])
      @qbit_longest_time_on_same_port = helpers.seconds_to_s(@qbit_stats[:same_port])

      erb :index
    end

    get '/api-docs' do
      update = Notification.select(:info, :active).where(name: 'update_available').first
      @recent_tag = update[:info]
      @update_available = update[:active]

      erb :api_docs
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

      service = params['select']&.strip&.downcase&.shellescape
      public_ip = helpers.get_public_ip(service)
      @public_ip = "#{service} -> #{public_ip}"

      erb :tools
    end

    get '/logs' do
      helpers = Service::Helpers.new

      update = Notification.select(:info, :active).where(name: 'update_available').first
      @recent_tag = update[:info]
      @update_available = update[:active]

      @log_lines = helpers.env_variables[:log_lines]
      @output = helpers.log_lines_to_a(@log_lines)

      erb :logs
    end

    get '/about' do # rubocop:disable Metrics/BlockLength
      helpers = Service::Helpers.new

      update = Notification.select(:info, :active).where(name: 'update_available').first
      @recent_tag = update[:info]
      @update_available = update[:active]

      @app_version = ENV['VERSION']
      @schema_version = helpers.get_db_version
      @ruby_version = "#{RUBY_VERSION} (p#{RUBY_PATCHLEVEL})"
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
      @qbit_skip = helpers.true?(ENV['QBIT_SKIP'])
      @qbit_addr = ENV['QBIT_ADDR']
      @qbit_user = ENV['QBIT_USER']
      @qbit_pass = '***'

      @gemfile = helpers.gemfile_to_a

      erb :about
    end
  end
end
