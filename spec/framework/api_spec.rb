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

  def api_post(path, body, token: @api_token, scheme: 'Bearer')
    headers = token ? { 'HTTP_AUTHORIZATION' => "#{scheme} #{token}" } : {}
    Rack::MockRequest.new(app).post(
      path,
      headers.merge('CONTENT_TYPE' => 'application/json', input: body.to_json)
    )
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
    ENV['OPN_SKIP'] = 'true'
    allow_any_instance_of(Service::Helpers).to receive(:generate_wg_public_key).and_return('public-key')

    response = api_get('/api/tools/pubkey?private-key=private-key')

    expect(response_json(response)['public_key']).to eq('public-key')
  end

  it 'returns selectable OPNsense WireGuard targets' do
    ENV['OPN_SKIP'] = 'false'
    targets = {
      instances: [{ uuid: '11111111-1111-4111-8111-111111111111', name: 'proton-instance' }],
      peers: [{ uuid: '22222222-2222-4222-8222-222222222222', name: 'proton-peer' }]
    }
    allow_any_instance_of(Service::Opnsense).to receive(:wireguard_targets).and_return(targets)

    response = api_get('/api/tools/wireguard-targets')

    expect(response.status).to eq(200)
    expect(response_json(response)['wireguard_targets']).to eq(JSON.parse(targets.to_json))
  end

  it 'does not load WireGuard targets when OPNsense integration is skipped' do
    ENV['OPN_SKIP'] = 'true'
    expect(Service::Opnsense).not_to receive(:new)

    response = api_get('/api/tools/wireguard-targets')

    expect(response.status).to eq(503)
    expect(response_json(response)['error']).to eq(
      'Proton WireGuard import is unavailable because OPNsense integration is disabled.'
    )
  end

  it 'does not parse or rotate WireGuard configuration when OPNsense integration is skipped' do
    ENV['OPN_SKIP'] = 'true'
    submitted_config = "[Interface]\nPrivateKey = distinctive-skipped-api-private-config-value"
    expect(Service::Opnsense).not_to receive(:new)
    expect(Service::ProtonWireguard).not_to receive(:new)
    expect(Service::ProtonWireguardRotation).not_to receive(:new)

    response = api_post(
      '/api/tools/wireguard-import',
      { config: submitted_config, instance_uuid: 'instance', peer_uuid: 'peer' }
    )

    expect(response.status).to eq(503)
    expect(response_json(response)['error']).to eq(
      'Proton WireGuard import is unavailable because OPNsense integration is disabled.'
    )
    expect(response.body).not_to include('distinctive-skipped-api-private-config-value', 'PrivateKey')
  end

  it 'completes a ProtonVPN WireGuard rotation without returning its private values' do # rubocop:disable Metrics/BlockLength
    ENV['OPN_SKIP'] = 'false'
    instance_uuid = '11111111-1111-4111-8111-111111111111'
    peer_uuid = '22222222-2222-4222-8222-222222222222'
    parsed = {
      instance: { private_key: 'private-key' },
      peer: {},
      metadata: { proton_server_identifier: 'US-IL#661' }
    }
    allow_any_instance_of(Service::ProtonWireguard).to receive(:import).and_return(parsed)
    rotation = instance_double(Service::ProtonWireguardRotation)
    allow(Service::ProtonWireguardRotation).to receive(:new).and_return(rotation)
    expect(rotation).to receive(:rotate).with(
      parsed,
      instance_uuid: instance_uuid,
      peer_uuid: peer_uuid,
      rename_peer: true
    ).and_return(instance_name: 'proton-instance', peer_name: 'Proton_US-IL661')

    response = api_post(
      '/api/tools/wireguard-import',
      {
        config: "[Interface]\nPrivateKey = distinctive-private-config-value",
        instance_uuid: instance_uuid,
        peer_uuid: peer_uuid,
        rename_peer: true
      }
    )
    body = response_json(response)

    expect(response.status).to eq(200)
    expect(body['wireguard_import']).to eq(
      'instance_name' => 'proton-instance', 'peer_name' => 'Proton_US-IL661'
    )
    expect(response.body).not_to include('private-key', 'distinctive-private-config-value', '[Interface]')
  end

  it 'rejects requested peer renaming without server metadata before contacting OPNsense' do
    instance_uuid = '11111111-1111-4111-8111-111111111111'
    peer_uuid = '22222222-2222-4222-8222-222222222222'
    allow_any_instance_of(Service::ProtonWireguard).to receive(:import).and_return(
      instance: {}, peer: {}, metadata: {}
    )
    opnsense = instance_double(Service::Opnsense)
    allow(Service::Opnsense).to receive(:new).and_return(opnsense)

    response = api_post(
      '/api/tools/wireguard-import',
      {
        config: '[Interface]',
        instance_uuid: instance_uuid,
        peer_uuid: peer_uuid,
        rename_peer: true
      }
    )

    expect(response.status).to eq(422)
    expect(response_json(response)['error']).to include(
      'Unable to rename peer because a Proton server identifier was not found'
    )
  end

  it 'returns conflict when another WireGuard rotation is in progress' do
    allow_any_instance_of(Service::ProtonWireguard).to receive(:import).and_return(
      instance: {}, peer: {}
    )
    rotation = instance_double(Service::ProtonWireguardRotation)
    allow(Service::ProtonWireguardRotation).to receive(:new).and_return(rotation)
    allow(rotation).to receive(:rotate)
      .and_raise(Service::ProtonWireguardRotation::Busy, 'another rotation is already in progress')

    response = api_post(
      '/api/tools/wireguard-import',
      { config: '[Interface]', instance_uuid: 'instance', peer_uuid: 'peer' }
    )

    expect(response.status).to eq(409)
    expect(response_json(response)['error']).to include('another rotation is already in progress')
  end

  it 'returns the rollback outcome when a synchronous WireGuard rotation fails' do
    allow_any_instance_of(Service::ProtonWireguard).to receive(:import).and_return(
      instance: { private_key: 'private-key' }, peer: {}
    )
    rotation = instance_double(Service::ProtonWireguardRotation)
    allow(Service::ProtonWireguardRotation).to receive(:new).and_return(rotation)
    allow(rotation).to receive(:rotate).and_raise(
      Service::ProtonWireguardRotation::Error,
      'OPNsense WireGuard rotation failed: apply failed; rollback completed'
    )

    response = api_post(
      '/api/tools/wireguard-import',
      { config: '[Interface]', instance_uuid: 'instance', peer_uuid: 'peer' }
    )

    expect(response.status).to eq(422)
    expect(response_json(response)['error']).to end_with('apply failed; rollback completed')
    expect(response.body).not_to include('private-key', '[Interface]')
  end

  it 'returns unknown provider details for unsupported public IP providers' do
    ENV['OPN_SKIP'] = 'true'
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
