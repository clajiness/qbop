module Framework
  # This class defines an API using the Grape framework.
  # It sets the response format to JSON and prefixes all routes with '/api'.
  # The API includes a single endpoint '/stats' that retrieves statistics from a SQLite3 database.
  # The statistics include current port information for ProtonVPN, OPNsense, and qBittorrent.
  class API < Grape::API
    format :json
    prefix :api

    get '/stats' do
      SQLite3::Database.open 'data/prod.db' do |db|
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
end
