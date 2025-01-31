class API < Grape::API # rubocop:disable Style/Documentation
  format :json
  prefix :api

  get '/stats' do
    SQLite3::Database.new 'data/prod.db' do |db|
      db.results_as_hash = true
      @stats = db.execute('select * from stats where id = 1').first
    end

    { 'stats' => {
      'protonvpn' => {
        'current_port': @stats['proton_current_port']
      },
      'opnsense' => {
        'current_port': @stats['opn_current_port'],
        'updated_at': @stats['opn_updated_at']
      },
      'qbit' => {
        'current_port': @stats['qbit_current_port'],
        'updated_at': @stats['qbit_updated_at']
      }
    } }
  end
end
