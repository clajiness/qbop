module Framework
  # The Web class is a Sinatra application that provides three routes:
  # - The root route ('/') which connects to an SQLite3 database to fetch statistics and renders the index view.
  # - The '/logs' route which reads the last specified number of lines from a log file and renders the logs view.
  # - The '/about' route which provides information about the repository, script version, Ruby version,
  # and system uptime, and renders the about view.
  class Web < Sinatra::Application
    get '/' do
      SQLite3::Database.open 'data/prod.db' do |db|
        db.results_as_hash = true
        @stats = db.execute('select * from stats where id = 1').first
      end

      erb :index
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
      @repo_url = 'https://github.com/clajiness/qbop'
      @script_version = ENV['VERSION']
      @ruby_version = "#{RUBY_VERSION} (p#{RUBY_PATCHLEVEL})"
      @uptime = `uptime -p`.strip

      erb :about
    end
  end
end
