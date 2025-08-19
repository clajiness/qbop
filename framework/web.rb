module Framework
  # The Web class is a Sinatra application that provides three routes
  # for displaying statistics, logs, and about information.
  class Web < Sinatra::Application
    get '/' do
      stats = Service::Stats.new.get_all
      helpers = Service::Helpers.new
      notification = Service::Notification.new

      @update_available = helpers.true?(notification.get_update_available)
      @recent_tag = notification.get_update_version

      @stats = stats

      @proton_connected = helpers.connected_to_service?(stats['proton_last_checked'])
      @opn_connected = helpers.connected_to_service?(stats['opn_last_checked'])
      @qbit_connected = helpers.connected_to_service?(stats['qbit_last_checked'])

      @proton_delta = helpers.time_delta_to_s(stats['proton_last_checked'], stats['proton_updated_at'])
      @opn_delta = helpers.time_delta_to_s(stats['opn_last_checked'], stats['opn_updated_at'])
      @qbit_delta = helpers.time_delta_to_s(stats['qbit_last_checked'], stats['qbit_updated_at'])

      @opn_skip = helpers.true?(ENV['OPN_SKIP'])
      @qbit_skip = helpers.true?(ENV['QBIT_SKIP'])

      @proton_longest_time_on_same_port = helpers.get_proton_longest_time_on_same_port_to_s
      @opn_longest_time_on_same_port = helpers.get_opn_longest_time_on_same_port_to_s
      @qbit_longest_time_on_same_port = helpers.get_qbit_longest_time_on_same_port_to_s

      erb :index
    end

    get '/api-docs' do
      helpers = Service::Helpers.new
      notification = Service::Notification.new

      @update_available = helpers.true?(notification.get_update_available)
      @recent_tag = notification.get_update_version

      erb :api_docs
    end

    get '/logs' do
      helpers = Service::Helpers.new
      notification = Service::Notification.new

      @update_available = helpers.true?(notification.get_update_available)
      @recent_tag = notification.get_update_version

      log_lines = helpers.env_variables[:log_lines]
      output = []

      File.readlines('data/log/qbop.log').last(log_lines.to_i).each do |line|
        output << line
      end

      @output = output
      @log_lines = helpers.true?(helpers.env_variables[:log_reverse]) ? output.reverse : output

      erb :logs
    end

    get '/about' do
      helpers = Service::Helpers.new
      notification = Service::Notification.new

      @app_version = ENV['VERSION']
      @update_available = helpers.true?(notification.get_update_available)
      @recent_tag = notification.get_update_version
      @app_uptime = helpers.job_uptime_to_s
      @schema_version = helpers.get_db_version
      @ruby_version = "#{RUBY_VERSION} (p#{RUBY_PATCHLEVEL})"
      @repo_url = 'https://github.com/clajiness/qbop'

      @ui_mode = ENV['UI_MODE']
      @loop_freq = ENV['LOOP_FREQ']
      @required_attempts = ENV['REQUIRED_ATTEMPTS']
      @log_lines = ENV['LOG_LINES']
      @log_reverse = helpers.true?(ENV['LOG_REVERSE'])
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

      erb :about
    end
  end
end
