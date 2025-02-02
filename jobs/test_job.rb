class TestJob # rubocop:disable Style/Documentation
  include SuckerPunch::Job

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
