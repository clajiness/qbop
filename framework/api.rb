class API < Grape::API # rubocop:disable Style/Documentation
  format :json
  prefix :api

  get '/stats' do
    SQLite3::Database.new 'data/prod.db' do |db|
      db.results_as_hash = true
      @stats = db.execute('select * from stats where id = 1').first
    end

    { 'stats' => { 'current_port': @stats['current_port'], 'updated_at': @stats['updated_at'] } }
  end
end
