class TestJob # rubocop:disable Style/Documentation
  include SuckerPunch::Job

  def perform # rubocop:disable Metrics/MethodLength
    @logger = Logger.new('data/log/qbop.log', 10, 5_120_000)
    @logger.info('starting TestJob...')

    counter = Service::Counter.new

    loop do
      @logger.info("I'm doing some testing")

      pp counter.required_attempts
      pp counter.opnsense_attempt

      @logger.info('Sleeping for 30 seconds...')
      @logger.info('----------')
      sleep 30
    end
  end
end
