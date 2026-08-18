require 'bundler/setup'
Bundler.require(:default)

require 'rack/mock'
require_relative '../support/database_helper'
require_relative '../../service/helpers'
require_relative '../../framework/uptime'
require_relative '../../framework/api'

SpecDatabase.reset!

RSpec.describe Framework::API do # rubocop:disable Metrics/BlockLength
  def app
    described_class
  end

  def response_json(response)
    JSON.parse(response.body)
  end

  def api_get(path, token: @api_token, scheme: 'Bearer')
    headers = token ? { 'HTTP_AUTHORIZATION' => "#{scheme} #{token}" } : {}
    Rack::MockRequest.new(app).get(path, headers)
  end

  around do |example|
    env_keys = %w[OPN_SKIP QBIT_SKIP VERSION COMMIT_SHA BUILD_DATE]
    original_env = env_keys.to_h { |key| [key, ENV[key]] }

    env_keys.each { |key| ENV.delete(key) }
    example.run
  ensure
    env_keys.each { |key| original_env[key].nil? ? ENV.delete(key) : ENV[key] = original_env[key] }
  end

  before do
    SpecDatabase.reset!
    %w[proton opnsense qbit].each do |name|
      source = Source.create(name: name)
      Stat.create(
        source_id: source.id,
        current_port: 12_345,
        same_port: 60,
        last_checked: Time.now,
        updated_at: Time.now
      )
    end
    issued_key = ApiKey.issue('api spec')
    @api_key = issued_key.api_key
    @api_token = issued_key.token
  end

  it 'requires the same valid Bearer credential for every API endpoint' do
    missing = api_get('/api/stats', token: nil)
    invalid = api_get('/api/stats', token: "#{ApiKey::TOKEN_PREFIX}#{'0' * 64}")
    basic = api_get('/api/stats', token: @api_token, scheme: 'Basic')

    [missing, invalid, basic].each do |response|
      expect(response.status).to eq(401)
      expect(response_json(response)).to eq('error' => 'unauthorized')
      expect(response['www-authenticate']).to eq('Bearer realm="qbop"')
    end
    expect(api_get('/api/stats').status).to eq(200)
    expect(api_get('/api/health').status).to eq(200)
  end

  it 'updates last use only after successful authentication' do
    expect(api_get('/api/health', token: nil).status).to eq(401)
    expect(api_get('/api/health', token: "#{ApiKey::TOKEN_PREFIX}#{'0' * 64}").status).to eq(401)
    expect(@api_key.refresh.last_used_at).to be_nil

    expect(api_get('/api/health').status).to eq(200)
    expect(@api_key.refresh.last_used_at).not_to be_nil
  end

  it 'supports independent keys and revokes only the deleted key' do
    other = ApiKey.issue('other client')

    expect(api_get('/api/stats').status).to eq(200)
    expect(api_get('/api/stats', token: other.token).status).to eq(200)

    @api_key.delete

    expect(api_get('/api/stats').status).to eq(401)
    expect(api_get('/api/stats', token: other.token).status).to eq(200)
  end

  it 'returns stats by source name' do
    response = api_get('/api/stats')
    body = response_json(response)

    expect(response.status).to eq(200)
    expect(body.dig('stats', 'protonvpn', 'current_port')).to eq(12_345)
    expect(body.dig('records', 'longest_time_on_same_port', 'qbit')).to eq(60)
  end

  it 'returns healthy status when all services checked in recently' do
    response = api_get('/api/health')

    expect(response.status).to eq(200)
    expect(response_json(response)['health'].values).to all(eq(200))
  end

  it 'returns unhealthy status when any service is stale' do
    DB[:stats].where(source_id: Source[name: 'qbit'].id).update(last_checked: Time.now - 10_000)

    response = api_get('/api/health')

    expect(response.status).to eq(503)
    expect(response_json(response).dig('health', 'qbit')).to eq(503)
  end

  it 'ignores skipped services for health status' do
    ENV['QBIT_SKIP'] = 'true'
    DB[:stats].where(source_id: Source[name: 'qbit'].id).update(last_checked: Time.now - 10_000)

    response = api_get('/api/health')

    expect(response.status).to eq(200)
    expect(response_json(response).dig('health', 'qbit')).to eq('skipped')
  end

  it 'returns a default notification when no notification exists' do
    response = api_get('/api/notifications')

    expect(response_json(response)['notifications']).to eq(
      'name' => 'update_available',
      'info' => nil,
      'active' => false
    )
  end

  it 'returns the update notification when it exists' do
    Notification.create(name: 'update_available', info: 'v2.7.0', active: true)

    response = api_get('/api/notifications')

    expect(response_json(response)['notifications']).to include('info' => 'v2.7.0', 'active' => true)
  end

  it 'returns public key tool output' do
    allow_any_instance_of(Service::Helpers).to receive(:generate_wg_public_key).and_return('public-key')

    response = api_get('/api/tools/pubkey?private-key=private-key')

    expect(response_json(response)['public_key']).to eq('public-key')
  end

  it 'returns unknown provider details for unsupported public IP providers' do
    response = api_get('/api/tools/public-ip?service=invalid')

    expect(response_json(response)['public_ip']).to start_with('Unknown provider')
  end

  it 'returns log lines' do
    allow_any_instance_of(Service::Helpers).to receive(:log_lines_to_a).and_return(["line one\n", "line two\n"])

    response = api_get('/api/logs')

    expect(response_json(response)['log_lines']).to eq(['line one', 'line two'])
  end

  it 'returns log lines using query string controls' do
    expect_any_instance_of(Service::Helpers)
      .to receive(:log_lines_to_a)
      .with(500, true)
      .and_return(["line one\n", "line two\n"])

    response = api_get('/api/logs?lines=500&direction=desc')

    expect(response_json(response)).to eq('log_lines' => ['line one', 'line two'])
  end

  it 'returns paginated port transition history' do # rubocop:disable Metrics/BlockLength
    30.times do |index|
      PortTransition.record_transition(
        previous_port: index + 10_000,
        new_port: index + 10_001,
        opnsense_skipped: false,
        qbit_skipped: index.zero?,
        detected_at: Time.at(index)
      )
    end
    PortTransition.mark_synced('opnsense', 10_001, at: Time.at(30))
    PortTransition.mark_error('qbit', 10_002, at: Time.at(31))

    response = api_get('/api/history?page=2&per_page=25')
    body = response_json(response)

    expect(response.status).to eq(200)
    expect(body['history'].length).to eq(5)
    expect(body['history'].first['new_port']).to eq(10_005)
    expect(body['history'].last).to include(
      'previous_port' => 10_000,
      'new_port' => 10_001,
      'opnsense' => include('status' => 'synced'),
      'qbit' => include('status' => 'skipped')
    )
    errored_transition = body['history'].find { |transition| transition['new_port'] == 10_002 }
    expect(errored_transition['qbit']).to eq('status' => 'error', 'synced_at' => nil)
    expect(errored_transition['qbit']).not_to have_key('error_at')
    expect(body['pagination']).to eq(
      'total_records' => 30,
      'current_page' => 2,
      'per_page' => 25,
      'total_pages' => 2,
      'from' => 26,
      'to' => 30
    )
  end

  it 'constrains invalid history API pagination parameters' do
    PortTransition.record_transition(
      previous_port: 12_345,
      new_port: 23_456,
      opnsense_skipped: false,
      qbit_skipped: false
    )

    response = api_get('/api/history?page=999&per_page=500')
    pagination = response_json(response)['pagination']

    expect(pagination).to include(
      'current_page' => 1,
      'per_page' => 25,
      'total_records' => 1
    )
  end

  it 'returns about information' do
    ENV['VERSION'] = 'v2.9.0'
    ENV['COMMIT_SHA'] = '0123456789abcdef'
    ENV['BUILD_DATE'] = '2026-08-11T12:34:56Z'
    response = api_get('/api/about')
    body = response_json(response)

    expect(response.status).to eq(200)
    expect(body.dig('about', 'app_version')).to eq('v2.9.0')
    expect(body.dig('about', 'commit_sha')).to eq('0123456789abcdef')
    expect(body.dig('about', 'build_date')).to eq('2026-08-11T12:34:56Z')
    expect(body.dig('about', 'schema_version')).to eq('unknown')
    expect(body.dig('env_variables', 'opn_ssl_verify')).to eq(false)
    expect(body['env_variables'].keys).not_to include(
      'basic_auth_enabled', 'basic_auth_user', 'basic_auth_pass'
    )
  end
end
