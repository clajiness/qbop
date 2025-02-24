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

      helpers = Service::Helpers.new

      { 'stats' => {
        'protonvpn' => {
          'current_port': @stats['proton_current_port'],
          'last_checked': @stats['proton_last_checked']
        },
        'opnsense' => {
          'current_port': @stats['opn_current_port'],
          'last_checked': @stats['opn_last_checked'],
          'last_changed': @stats['opn_updated_at'],
          'delta': helpers.time_delta(@stats['opn_last_checked'], @stats['opn_last_updated'])
        },
        'qbit' => {
          'current_port': @stats['qbit_current_port'],
          'last_checked': @stats['qbit_last_checked'],
          'last_changed': @stats['qbit_updated_at'],
          'delta': helpers.time_delta(@stats['qbit_last_checked'], @stats['qbit_last_updated'])
        }
      } }
    end

    get '/about' do
      { 'about' => {
        app_version: ENV['VERSION'],
        schema_version: Service::Helpers.new.get_db_version,
        ruby_version: "#{RUBY_VERSION} (p#{RUBY_PATCHLEVEL})"
      } }
    end
  end
end
