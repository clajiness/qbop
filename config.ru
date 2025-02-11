require 'sucker_punch'
require 'bundler/setup'
Bundler.require(:default)
Dir['./framework/*.rb'].sort.each { |file| require_relative file }
Dir['./jobs/*.rb'].sort.each { |file| require_relative file }
Dir['./service/*.rb'].sort.each { |file| require_relative file }

# initialize database, if necessary
Service::DbInitialization.new unless File.exist?('data/prod.db')

# map sinatra and grape apps
map '/' do
  use Rack::Session::Cookie, secret: SecureRandom.alphanumeric(64)
  run Rack::Cascade.new([Framework::Web, Framework::API])

  # start the job(s)
  Qbop.perform_async
  # TestJob.perform_async
end
