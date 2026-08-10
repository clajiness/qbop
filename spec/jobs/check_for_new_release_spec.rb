require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'
require_relative '../../service/helpers'
require_relative '../../service/github'
require_relative '../../jobs/check_for_new_release'

RSpec.describe CheckForNewReleases do # rubocop:disable Metrics/BlockLength
  before do
    SpecDatabase.reset!
  end

  it 'fetches a tag once and persists update notification state' do
    logger = instance_double(Logger, info: nil, error: nil)
    helpers = instance_double(
      Service::Helpers,
      release_build?: true,
      update_available?: true,
      logger_instance: logger
    )
    github = instance_double(Service::Github, get_most_recent_tag: 'v2.7.0')
    job = described_class.new

    job.instance_variable_set(:@helpers, helpers)
    job.instance_variable_set(:@github, github)
    job.instance_variable_set(:@logger, logger)
    allow(job).to receive(:sleep)

    job.send(:run_loop_iteration)

    notification = Notification[name: 'update_available']
    expect(notification.info).to eq('v2.7.0')
    expect(notification.active).to eq(true)
    expect(helpers).to have_received(:update_available?).with('v2.7.0')
    expect(github).to have_received(:get_most_recent_tag).once
  end

  it 'disables release notifications without checking GitHub for main builds' do
    Notification.create(name: 'update_available', info: 'v2.7.0', active: true)
    logger = instance_double(Logger, info: nil, error: nil)
    helpers = instance_double(
      Service::Helpers,
      release_build?: false,
      app_version: 'main',
      logger_instance: logger
    )
    github = instance_double(Service::Github)
    job = described_class.new

    job.instance_variable_set(:@helpers, helpers)
    job.instance_variable_set(:@github, github)
    job.instance_variable_set(:@logger, logger)
    allow(job).to receive(:sleep)
    allow(github).to receive(:get_most_recent_tag)

    job.send(:run_loop_iteration)

    notification = Notification[name: 'update_available']
    expect(notification.info).to be_nil
    expect(notification.active).to eq(false)
    expect(github).not_to have_received(:get_most_recent_tag)
  end
end
