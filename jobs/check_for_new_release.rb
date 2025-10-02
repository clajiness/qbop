class CheckForNewReleases # rubocop:disable Style/Documentation
  include SuckerPunch::Job
  SuckerPunch.shutdown_timeout = 1

  def perform # rubocop:disable Metrics/MethodLength
    @logger = Logger.new('log/qbop.log', 10, 5_120_000)
    @logger.info('[CheckForNewReleases] starting new releases job...')

    helpers = Service::Helpers.new
    github = Service::Github.new

    loop do
      @logger.info('[CheckForNewReleases] checking for new releases...')

      # check for new release
      update_available = helpers.update_available?

      # get most recent tag
      tag = github.get_most_recent_tag

      # set update available status
      Notification.update_or_create({ name: 'update_available' }, info: tag, active: update_available)

      # log update available status
      if update_available
        @logger.info('[CheckForNewReleases] an update is available')
      else
        @logger.info('[CheckForNewReleases] no update available')
      end

      # check every 6 hours
      @logger.info('[CheckForNewReleases] sleeping for 6 hours')
      sleep 60 * 60 * 6
    end
  end
end
