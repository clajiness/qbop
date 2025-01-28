class Web < Sinatra::Application # rubocop:disable Style/Documentation
  get '/' do
    db = SQLite3::Database.new 'data/prod.db'
    @stats = db.execute('select * from stats').first
    db.close
    
    job_data = Sidekiq::Stats.new
    @jobs_processed = job_data.processed
    @jobs_failed = job_data.failed

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
end
