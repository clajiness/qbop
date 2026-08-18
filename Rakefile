namespace :db do
  desc 'Run migrations'
  task :migrate, [:version] do |_t, args|
    require 'sequel/core'
    Sequel.extension :migration
    version = args[:version].to_i if args[:version]
    Sequel.connect('sqlite://data/qbop.sqlite3') do |db|
      Sequel::Migrator.run(db, 'db/migrate', target: version)
    end
  end
end

namespace :user do
  desc 'Reset the administrator password'
  task :'reset-password' do
    require 'bundler/setup'
    Bundler.require(:default)

    unless defined?(DB)
      Rake::Task['db:migrate'].invoke
      Object.const_set(:DB, Sequel.connect('sqlite://data/qbop.sqlite3'))
      Sequel::Model.db = DB
    end

    require_relative 'service/helpers'
    require_relative 'framework/authentication'
    require_relative 'service/account_recovery'

    Service::AccountRecovery.new.reset_password
  rescue Service::AccountRecovery::Error => e
    abort e.message
  end
end
