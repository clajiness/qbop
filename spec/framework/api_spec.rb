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

  around do |example|
    opn_skip = ENV['OPN_SKIP']
    qbit_skip = ENV['QBIT_SKIP']

    ENV.delete('OPN_SKIP')
    ENV.delete('QBIT_SKIP')
    example.run
  ensure
    opn_skip.nil? ? ENV.delete('OPN_SKIP') : ENV['OPN_SKIP'] = opn_skip
    qbit_skip.nil? ? ENV.delete('QBIT_SKIP') : ENV['QBIT_SKIP'] = qbit_skip
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
  end

  it 'returns stats by source name' do
    response = Rack::MockRequest.new(app).get('/api/stats')
    body = response_json(response)

    expect(response.status).to eq(200)
    expect(body.dig('stats', 'protonvpn', 'current_port')).to eq(12_345)
    expect(body.dig('records', 'longest_time_on_same_port', 'qbit')).to eq(60)
  end

  it 'returns healthy status when all services checked in recently' do
    response = Rack::MockRequest.new(app).get('/api/health')

    expect(response.status).to eq(200)
    expect(response_json(response)['health'].values).to all(eq(200))
  end

  it 'returns unhealthy status when any service is stale' do
    DB[:stats].where(source_id: Source[name: 'qbit'].id).update(last_checked: Time.now - 10_000)

    response = Rack::MockRequest.new(app).get('/api/health')

    expect(response.status).to eq(503)
    expect(response_json(response).dig('health', 'qbit')).to eq(503)
  end

  it 'ignores skipped services for health status' do
    ENV['QBIT_SKIP'] = 'true'
    DB[:stats].where(source_id: Source[name: 'qbit'].id).update(last_checked: Time.now - 10_000)

    response = Rack::MockRequest.new(app).get('/api/health')

    expect(response.status).to eq(200)
    expect(response_json(response).dig('health', 'qbit')).to eq('skipped')
  end

  it 'returns a default notification when no notification exists' do
    response = Rack::MockRequest.new(app).get('/api/notifications')

    expect(response_json(response)['notifications']).to eq(
      'name' => 'update_available',
      'info' => nil,
      'active' => false
    )
  end

  it 'returns the update notification when it exists' do
    Notification.create(name: 'update_available', info: 'v2.7.0', active: true)

    response = Rack::MockRequest.new(app).get('/api/notifications')

    expect(response_json(response)['notifications']).to include('info' => 'v2.7.0', 'active' => true)
  end

  it 'returns public key tool output' do
    allow_any_instance_of(Service::Helpers).to receive(:generate_wg_public_key).and_return('public-key')

    response = Rack::MockRequest.new(app).get('/api/tools/pubkey?private-key=private-key')

    expect(response_json(response)['public_key']).to eq('public-key')
  end

  it 'returns unknown provider details for unsupported public IP providers' do
    response = Rack::MockRequest.new(app).get('/api/tools/public-ip?service=invalid')

    expect(response_json(response)['public_ip']).to start_with('Unknown provider')
  end

  it 'returns log lines' do
    allow_any_instance_of(Service::Helpers).to receive(:log_lines_to_a).and_return(["line one\n", "line two\n"])

    response = Rack::MockRequest.new(app).get('/api/logs')

    expect(response_json(response)['log_lines']).to eq(['line one', 'line two'])
  end

  it 'returns about information' do
    response = Rack::MockRequest.new(app).get('/api/about')
    body = response_json(response)

    expect(response.status).to eq(200)
    expect(body.dig('about', 'schema_version')).to eq('unknown')
    expect(body.dig('env_variables', 'opn_ssl_verify')).to eq(false)
  end
end
