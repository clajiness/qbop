require 'sidekiq-scheduler'

class DoSomeWork
  include Sidekiq::Job

  def perform
    sleep 5
    puts 'did some work'
  end
end
