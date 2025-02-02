# TestJob is a background job that logs a message every 5 seconds.
# It uses the SuckerPunch library to handle job processing.
# The log messages are written to 'data/log/qbop.log'.
class TestJob
  include SuckerPunch::Job
  SuckerPunch.shutdown_timeout = 1

  def perform
    @logger = Logger.new('data/log/qbop.log', 10, 5_120_000)
    @logger.info('starting TestJob...')

    loop do
      @logger.info("I'm doing some testing")

      # test here
      sleep 5
    end
  end
end
