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

  it 'renders update notification details when present' do
    Notification.create(name: 'update_available', info: 'v2.7.0', active: true)

    response = Rack::MockRequest.new(described_class).get('/about')

    expect(response.status).to eq(200)
    expect(response.body).to include('v2.7.0')
  end

  it 'renders tools and API docs pages' do
    expect(Rack::MockRequest.new(described_class).get('/tools').status).to eq(200)
    expect(Rack::MockRequest.new(described_class).get('/api-docs').status).to eq(200)
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
end
