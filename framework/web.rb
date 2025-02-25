module Framework
  # The Web class is a Sinatra application that provides three routes:
  # - The root route ('/') which connects to an SQLite3 database to fetch statistics and renders the index view.
  # - The '/logs' route which reads the last specified number of lines from a log file and renders the logs view.
  # - The '/about' route which provides information about the repository, script version, Ruby version,
  # and system uptime, and renders the about view.
  class Web < Sinatra::Application
    get '/' do
      stats = {}

      SQLite3::Database.open 'data/prod.db' do |db|
        db.results_as_hash = true
        stats = db.execute('select * from stats where id = 1').first
      end

      helpers = Service::Helpers.new

      @stats = stats

      @opn_delta = helpers.time_delta_to_s(stats['opn_last_checked'], stats['opn_updated_at'])
      @qbit_delta = helpers.time_delta_to_s(stats['qbit_last_checked'], stats['qbit_updated_at'])

      @opn_skip = helpers.skip_section?(ENV['OPN_SKIP'])
      @qbit_skip = helpers.skip_section?(ENV['QBIT_SKIP'])

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
      @schema_version = Service::Helpers.new.get_db_version
      @ruby_version = "#{RUBY_VERSION} (p#{RUBY_PATCHLEVEL})"
      @repo_url = 'https://github.com/clajiness/qbop'

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
