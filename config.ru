require 'sucker_punch'
require 'bundler/setup'
Bundler.require(:default)
Dir['./framework/*.rb'].sort.each { |file| require_relative file }
Dir['./jobs/*.rb'].sort.each { |file| require_relative file }
Dir['./service/*.rb'].sort.each { |file| require_relative file }

# initialize database and run migrations, if necessary
Service::DbInitialization.new unless File.exist?('data/prod.db')
Service::DbMigration.new

# map sinatra and grape apps
map '/' do
  use Rack::Session::Cookie, secret: SecureRandom.alphanumeric(64)
  run Rack::Cascade.new([Framework::Web, Framework::API])
end

# start the job(s)
Qbop.perform_async
CheckForNewReleases.perform_async
