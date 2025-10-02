# TestJob is a background job that logs a message every 5 seconds.
class TestJob
  include SuckerPunch::Job
  SuckerPunch.shutdown_timeout = 1

  def perform
    @logger = Logger.new('log/qbop.log', 10, 5_120_000)
    @logger.info('[TestJob] starting TestJob...')

    loop do
      @logger.info('[TestJob] doing some testing')

      # test here
      sleep 60
    end
  end
end
