class DoSomeWork # rubocop:disable Style/Documentation
  include SuckerPunch::Job

  def perform
    @logger = Logger.new('data/log/qbop.log', 10, 5_120_000)
    @logger.info('starting DoSomeWork...')

    loop do
      @logger.info("I'm doing some work!")
      @logger.info('Sleeping for 30 seconds...')
      @logger.info('----------')
      sleep 30
    end
  end
end
