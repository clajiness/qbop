require 'sucker_punch'
require 'bundler/setup'
Bundler.require(:default)
# Rodauth reads the Sequel connection during setup, so its Roda app loads below.
Dir['./framework/*.rb'].sort.reject { |file| file.end_with?('/authentication.rb') }.each do |file|
  require_relative file
end
Dir['./jobs/*.rb'].sort.each { |file| require_relative file }
Dir['./service/*.rb'].sort.each { |file| require_relative file }

# enable Sequel plugins
Sequel::Model.plugin :update_or_create

# run available migrations
load 'Rakefile'
Rake::Task['db:migrate'].invoke

# connect to the database and load models
DB = Sequel.connect('sqlite://data/qbop.sqlite3')
require_relative './framework/authentication'
Dir['./models/*.rb'].sort.each { |file| require_relative file }

# seed tables if empty
Service::Seed.new

# build the web application with Rodauth for the UI and optional Basic Auth for the API
run Framework::Application.build

# start the job(s)
Qbop.perform_async
CheckForNewReleases.perform_async
