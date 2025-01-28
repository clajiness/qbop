require 'sinatra/contrib'
require 'sidekiq/web'
require 'sidekiq-scheduler/web'
require 'bundler/setup'
Bundler.require(:default)
Dir['./service/*.rb'].sort.each { |file| require_relative file }
Dir['./jobs/*.rb'].sort.each { |file| require_relative file }

# initialize database, if necessary
Service::DbInitialization.new unless File.exist?('data/prod.db')

# set up secret for cookie
secret = SecureRandom.alphanumeric(64)

# map sinatra and grape apps
map '/' do
  use Rack::Session::Cookie, secret: secret
  run Rack::Cascade.new([Web, API])
end

# map sidekiq web
map '/sidekiq' do
  use Rack::Session::Cookie, secret: secret
  run Sidekiq::Web
end
