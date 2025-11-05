# TestJob is a background job that logs a message every 5 seconds.
class TestJob
  include SuckerPunch::Job
  SuckerPunch.shutdown_timeout = 1

  def perform
    @logger = helpers.logger_instance
    @logger.info('[TestJob] starting TestJob...')

    loop do
      @logger.info('[TestJob] doing some testing')

      # test here
      sleep 60
    end
  end
end
