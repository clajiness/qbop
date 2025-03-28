# TestJob is a background job that logs a message every 5 seconds.
class TestJob
  include SuckerPunch::Job
  SuckerPunch.shutdown_timeout = 1

  def perform
    @logger = Logger.new('data/log/qbop.log', 10, 5_120_000)
    @logger.info('starting TestJob...')

    stats = Service::Stats.new
    stats.set_job_started_at

    loop do
      @logger.info("I'm doing some testing")

      # test here
      sleep 5
    end
  end
end
