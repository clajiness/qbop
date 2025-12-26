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

# enable basic auth if configured
helpers = Service::Helpers.new
if helpers.env_variables[:basic_auth_enabled] == 'true'
  use Rack::Auth::Basic, 'Restricted Content' do |username, password|
    username.eql?(helpers.env_variables[:basic_auth_user]) and password.eql?(helpers.env_variables[:basic_auth_pass])
  end
end

# map sinatra and grape apps
map '/' do
  use Rack::Session::Cookie, secret: SecureRandom.alphanumeric(64)
  run Rack::Cascade.new([Framework::Web, Framework::API])
end

# start the job(s)
Qbop.perform_async
CheckForNewReleases.perform_async
