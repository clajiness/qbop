module Framework
  # The Web class is a Sinatra application that provides three routes
  # for displaying statistics, logs, and about information.
  class Web < Sinatra::Application
    get '/' do
      stats = Service::Stats.new.get_all
      helpers = Service::Helpers.new

      @stats = stats

      @proton_connected = helpers.connected_to_service?(stats['proton_last_checked'])
      @opn_connected = helpers.connected_to_service?(stats['opn_last_checked'])
      @qbit_connected = helpers.connected_to_service?(stats['qbit_last_checked'])

      @proton_delta = helpers.time_delta_to_s(stats['proton_last_checked'], stats['proton_updated_at'])
      @opn_delta = helpers.time_delta_to_s(stats['opn_last_checked'], stats['opn_updated_at'])
      @qbit_delta = helpers.time_delta_to_s(stats['qbit_last_checked'], stats['qbit_updated_at'])

      @opn_skip = helpers.skip_section?(ENV['OPN_SKIP'])
      @qbit_skip = helpers.skip_section?(ENV['QBIT_SKIP'])

      @proton_longest_time_on_same_port = helpers.get_proton_longest_time_on_same_port_to_s
      @opn_longest_time_on_same_port = helpers.get_opn_longest_time_on_same_port_to_s
      @qbit_longest_time_on_same_port = helpers.get_qbit_longest_time_on_same_port_to_s

      erb :index
    end

    get '/api-docs' do
      erb :api_docs
    end

    get '/logs' do
      log_lines = ENV['LOG_LINES'] || 50
      output = []

      File.readlines('data/log/qbop.log').last(log_lines.to_i).each do |line|
        output << line
      end

      @output = output
      @log_lines = log_lines

      erb :logs
    end

    get '/about' do
      helpers = Service::Helpers.new

      @app_version = ENV['VERSION']
      @app_uptime = helpers.job_uptime_to_s
      @schema_version = helpers.get_db_version
      @ruby_version = "#{RUBY_VERSION} (p#{RUBY_PATCHLEVEL})"
      @repo_url = 'https://github.com/clajiness/qbop'

      @ui_mode = ENV['UI_MODE']
      @loop_freq = ENV['LOOP_FREQ']
      @required_attempts = ENV['REQUIRED_ATTEMPTS']
      @log_lines = ENV['LOG_LINES']
      @proton_gateway = ENV['PROTON_GATEWAY']
      @opn_skip = helpers.skip_section?(ENV['OPN_SKIP'])
      @opn_interface_addr = ENV['OPN_INTERFACE_ADDR']
      @opn_api_key = '***'
      @opn_api_secret = '***'
      @opn_proton_alias_name = ENV['OPN_PROTON_ALIAS_NAME']
      @qbit_skip = helpers.skip_section?(ENV['QBIT_SKIP'])
      @qbit_addr = ENV['QBIT_ADDR']
      @qbit_user = ENV['QBIT_USER']
      @qbit_pass = '***'

      erb :about
    end
  end
end
