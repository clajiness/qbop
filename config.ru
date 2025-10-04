require 'sucker_punch'
require 'bundler/setup'
Bundler.require(:default)
Dir['./framework/*.rb'].sort.each { |file| require_relative file }
Dir['./jobs/*.rb'].sort.each { |file| require_relative file }
Dir['./service/*.rb'].sort.each { |file| require_relative file }

# enable Sequel plugins
Sequel::Model.plugin :update_or_create

# run available migrations
load 'Rakefile'
Rake::Task['db:migrate'].invoke

# connect to the database and load models
DB = Sequel.connect('sqlite://data/qbop.sqlite3')
Dir['./models/*.rb'].sort.each { |file| require_relative file }

# seed tables if empty
Service::Seed.new

# map sinatra and grape apps
map '/' do
  use Rack::Session::Cookie, secret: SecureRandom.alphanumeric(64)
  run Rack::Cascade.new([Framework::Web, Framework::API])
end

# start the job(s)
Qbop.perform_async
CheckForNewReleases.perform_async
