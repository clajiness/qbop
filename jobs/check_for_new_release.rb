class CheckForNewReleases # rubocop:disable Style/Documentation
  include SuckerPunch::Job
  SuckerPunch.shutdown_timeout = 1
  CHECK_INTERVAL = 60 * 60 * 6

  def perform
    initialize_dependencies
    @logger.info('[CheckForNewReleases] starting new releases job...')

    loop do
      run_loop_iteration
    end
  end

  private

  def initialize_dependencies
    @helpers = Service::Helpers.new
    @github = Service::Github.new
    @logger = @helpers.logger_instance
  end

  def run_loop_iteration # rubocop:disable Metrics/MethodLength
    @logger.info('[CheckForNewReleases] checking for new releases...')

    update_available = @helpers.update_available?
    tag = @github.get_most_recent_tag

    persist_notification(tag, update_available)
    log_update_status(update_available)

    @logger.info('[CheckForNewReleases] sleeping for 6 hours')
    sleep CHECK_INTERVAL
  rescue StandardError => e
    log_error(e)
    @logger.info('[CheckForNewReleases] sleeping for 6 hours')
    sleep CHECK_INTERVAL
  end

  def persist_notification(tag, update_available)
    Notification.update_or_create(
      { name: 'update_available' },
      info: tag,
      active: update_available
    )
  end

  def log_update_status(update_available)
    if update_available
      @logger.info('[CheckForNewReleases] an update is available')
    else
      @logger.info('[CheckForNewReleases] no update available')
    end
  end

  def log_error(error)
    @logger.error('[CheckForNewReleases] error while checking for releases:')
    @logger.error(error)
  end
end
