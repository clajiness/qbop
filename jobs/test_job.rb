class TestJob # rubocop:disable Style/Documentation
  include SuckerPunch::Job

  def perform # rubocop:disable Metrics/MethodLength
    @logger = Logger.new('data/log/qbop.log', 10, 5_120_000)
    @logger.info('starting TestJob...')

    stats = Service::Status.new
    loop do
      @logger.info("I'm doing some testing")

      # test here
      sleep 30
      stats.set_proton_current_port(6969)
      stats.set_opn_current_port(6969)
      stats.set_opn_updated_at
      stats.set_qbit_current_port(6969)
      stats.set_qbit_updated_at

      @logger.info('Sleeping for 30 seconds...')
      @logger.info('----------')
      sleep 30
    end
  end
end
