require 'bundler/setup'
Bundler.require(:default)

require 'rack/mock'
require_relative '../support/database_helper'
require_relative '../../service/helpers'
require_relative '../../framework/uptime'
require_relative '../../framework/web'

SpecDatabase.reset!
Framework::Web.set :environment, :test
Framework::Web.set :run, false
Framework::Web.set :views, File.expand_path('../../views', __dir__)

RSpec.describe Framework::Web do # rubocop:disable Metrics/BlockLength
  around do |example|
    version = ENV['VERSION']
    commit_sha = ENV['COMMIT_SHA']
    build_date = ENV['BUILD_DATE']
    web_auth_enabled = ENV['WEB_AUTH_ENABLED']
    ENV.delete('VERSION')
    ENV.delete('COMMIT_SHA')
    ENV.delete('BUILD_DATE')
    ENV['WEB_AUTH_ENABLED'] = 'false'
    example.run
  ensure
    version.nil? ? ENV.delete('VERSION') : ENV['VERSION'] = version
    commit_sha.nil? ? ENV.delete('COMMIT_SHA') : ENV['COMMIT_SHA'] = commit_sha
    build_date.nil? ? ENV.delete('BUILD_DATE') : ENV['BUILD_DATE'] = build_date
    web_auth_enabled.nil? ? ENV.delete('WEB_AUTH_ENABLED') : ENV['WEB_AUTH_ENABLED'] = web_auth_enabled
  end

  before do
    SpecDatabase.reset!
    %w[proton opnsense qbit].each do |name|
      source = Source.create(name: name)
      Stat.create(source_id: source.id, current_port: 12_345, same_port: 60)
    end
  end

  it 'renders the stats page without an update notification row' do
    response = Rack::MockRequest.new(described_class).get('/')

    expect(response.status).to eq(200)
    expect(response.body).to include('protonvpn')
    expect(response.body).to include('unknown')
  end

  it 'renders the stats page with meta refresh when requested' do
    response = Rack::MockRequest.new(described_class).get('/?refresh=5')

    expect(response.status).to eq(200)
    expect(response.body).to include('<meta http-equiv="refresh" content="5" />')
  end

  it 'renders update notification details when present' do
    ENV['VERSION'] = 'v2.6.0'
    Notification.create(name: 'update_available', info: 'v2.7.0', active: true)

    response = Rack::MockRequest.new(described_class).get('/about')

    expect(response.status).to eq(200)
    expect(response.body).to include('v2.7.0')
    expect(response.body).to match(
      %r{<h4><em>image</em></h4>\s*<blockquote>\s*commit:\s*unknown\s*<br>\s*built: unknown\s*</blockquote>}
    )
    headings = response.body.scan(%r{<h4><em>(.*?)</em></h4>}).flatten
    expect(headings.first(6)).to eq(
      ['app version', 'image', 'schema version', 'ruby version', 'app uptime', 'github repo']
    )
    expect(headings).not_to include('commit', 'build date')
  end

  it 'renders main build identity without a release status' do
    ENV['VERSION'] = 'main'
    ENV['COMMIT_SHA'] = '0123456789abcdef'
    ENV['BUILD_DATE'] = '2026-08-11T12:34:56Z'
    Notification.create(name: 'update_available', info: 'v2.7.0', active: true)

    response = Rack::MockRequest.new(described_class).get('/about')

    expect(response.status).to eq(200)
    expect(response.body).to include('tracking main')
    expect(response.body.scan('<h4><em>image</em></h4>').length).to eq(1)
    expect(response.body).to match(
      %r{
        <h4><em>image</em></h4>\s*
        <blockquote>\s*commit:\s*<a [^>]+>0123456789ab</a>\s*
        <br>\s*built:\s*2026-08-11T12:34:56Z\s*</blockquote>
      }x
    )
    expect(response.body).not_to include('an update is available')
  end

  it 'renders tools and API docs pages' do
    expect(Rack::MockRequest.new(described_class).get('/tools').status).to eq(200)
    api_docs_response = Rack::MockRequest.new(described_class).get('/api-docs')

    expect(api_docs_response.status).to eq(200)
    expect(api_docs_response.body).to include('/api/history?page=1&amp;per_page=25')
  end

  it 'renders public key tool results' do
    allow_any_instance_of(Service::Helpers).to receive(:generate_wg_public_key).and_return('public-key')

    response = Rack::MockRequest.new(described_class).post('/pubkey', input: 'privatekey=private-key')

    expect(response.status).to eq(200)
    expect(response.body).to include('public-key')
  end

  it 'renders public IP tool results' do
    allow_any_instance_of(Service::Helpers).to receive(:get_public_ip).and_return('192.0.2.1')

    response = Rack::MockRequest.new(described_class).post('/public-ip', input: 'select=akamai')

    expect(response.status).to eq(200)
    expect(response.body).to include('akamai -> 192.0.2.1')
  end

  it 'renders logs' do
    allow_any_instance_of(Service::Helpers).to receive(:log_lines_to_a).and_return(['log line'])

    response = Rack::MockRequest.new(described_class).get('/logs')

    expect(response.status).to eq(200)
    expect(response.body).to include('log line')
  end

  it 'renders logs with query string controls' do
    expect_any_instance_of(Service::Helpers).to receive(:log_lines_to_a).with(500, true).and_return(['new log'])

    response = Rack::MockRequest.new(described_class).get('/logs?lines=500&direction=desc&refresh=5')

    expect(response.status).to eq(200)
    expect(response.body).to include('new log')
    expect(response.body).to include('<meta http-equiv="refresh" content="5" />')
    expect(response.body).to include('last 500 lines of log output, newest first')
  end

  it 'renders an empty port transition history' do
    response = Rack::MockRequest.new(described_class).get('/history')

    expect(response.status).to eq(200)
    expect(response.body).to include('port transition history')
    expect(response.body).to include('no port transitions have been recorded yet')
  end

  it 'renders paginated port transitions with familiar controls' do
    30.times do |index|
      PortTransition.record_transition(
        previous_port: index + 10_000,
        new_port: index + 10_001,
        opnsense_skipped: false,
        qbit_skipped: index.zero?,
        detected_at: Time.at(index)
      )
    end

    response = Rack::MockRequest.new(described_class).get('/history?page=2&per_page=25&refresh=5')

    expect(response.status).to eq(200)
    expect(response.body).to include('showing 26&ndash;30 of 30 transitions, newest first')
    expect(response.body).to include('page 2 of 2')
    expect(response.body).to include('previous')
    expect(response.body).to include('skipped')
    expect(response.body).to include('value="25" selected')
    expect(response.body).to include('<meta http-equiv="refresh" content="5" />')
    expect(response.body).to include('/history?page=1&per_page=25&refresh=5')
    expect(response.body).to include('/history?page=2&per_page=25&refresh=0')
  end

  it 'constrains invalid history pagination parameters' do
    PortTransition.record_transition(
      previous_port: 12_345,
      new_port: 23_456,
      opnsense_skipped: false,
      qbit_skipped: false
    )

    response = Rack::MockRequest.new(described_class).get('/history?page=999&per_page=500')

    expect(response.status).to eq(200)
    expect(response.body).to include('showing 1&ndash;1 of 1 transitions')
    expect(response.body).to include('page 1 of 1')
    expect(response.body).to include('value="25" selected')
  end
end
