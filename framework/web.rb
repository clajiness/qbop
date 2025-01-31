class Web < Sinatra::Application # rubocop:disable Style/Documentation
  get '/' do
    SQLite3::Database.new 'data/prod.db' do |db|
      db.results_as_hash = true
      @stats = db.execute('select * from stats where id = 1').first
    end

    erb :index
  end

  get '/logs' do
    output = []
    File.readlines('data/log/qbop.log').last(50).each do |line|
      output << line
    end
    @output = output

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
