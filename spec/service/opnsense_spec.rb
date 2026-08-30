require 'bundler/setup'
Bundler.require(:default)

require 'webmock/rspec'

require_relative '../../service/opnsense'

RSpec.describe Service::Opnsense do # rubocop:disable Metrics/BlockLength
  let(:request_class) do
    Class.new(Struct.new(:headers, :body, :url_path, :params, :options)) do
      def initialize
        super({}, nil, nil, {}, Faraday::RequestOptions.new)
      end

      def url(path)
        self.url_path = path
      end
    end
  end

  let(:conn) { instance_double(Faraday::Connection) }
  let(:request) { request_class.new }
  let(:config) do
    {
      opnsense_interface_addr: 'https://opnsense.local',
      opnsense_api_key: 'test_api_key',
      opnsense_api_secret: 'test_api_secret',
      opnsense_alias_name: 'test_alias',
      opnsense_ssl_verify: false
    }
  end

  let(:instance_uuid) { '11111111-1111-4111-8111-111111111111' }
  let(:peer_uuid) { '22222222-2222-4222-8222-222222222222' }
  let(:other_instance_uuid) { '33333333-3333-4333-8333-333333333333' }

  it 'passes SSL verification config to Faraday' do
    allow(Faraday).to receive(:new).and_return(conn)

    described_class.new(config)

    expect(Faraday).to have_received(:new).with(
      url: 'https://opnsense.local',
      ssl: { verify: false },
      request: described_class::REQUEST_TIMEOUT
    )
  end

  it 'returns an alias UUID' do
    response = instance_double(Faraday::Response, body: '{"uuid":"alias-uuid"}')

    allow(Faraday).to receive(:new).and_return(conn)
    allow(conn).to receive(:get).and_yield(request).and_return(response)

    uuid = described_class.new(config).get_alias_uuid

    expect(request.url_path).to eq('/api/firewall/alias/get_alias_uuid/test_alias')
    expect(uuid).to eq('alias-uuid')
  end

  it 'returns an alias value' do
    response = instance_double(
      Faraday::Response,
      body: '{"alias":{"aliases":{"alias":{"alias-uuid":{"content":{"0":{"value":"54321"}}}}}}}'
    )

    allow(Faraday).to receive(:new).and_return(conn)
    allow(conn).to receive(:get).and_yield(request).and_return(response)

    value = described_class.new(config).get_alias_value('alias-uuid')

    expect(request.url_path).to eq('/api/firewall/alias/get')
    expect(value).to eq(54_321)
  end

  it 'sets an alias value' do
    response = instance_double(Faraday::Response)

    allow(Faraday).to receive(:new).and_return(conn)
    allow(conn).to receive(:post).and_yield(request).and_return(response)

    result = described_class.new(config).set_alias_value(54_321, 'alias-uuid')

    expect(result).to eq(response)
    expect(request.url_path).to eq('/api/firewall/alias/set_item/alias-uuid')
    expect(request.headers['Content-Type']).to eq('application/json')
    expect(request.body).to eq({ 'alias': { 'content': 54_321 } }.to_json)
  end

  it 'applies alias changes' do
    response = instance_double(Faraday::Response)

    allow(Faraday).to receive(:new).and_return(conn)
    allow(conn).to receive(:post).and_yield(request).and_return(response)

    expect(described_class.new(config).apply_changes).to eq(response)
    expect(request.url_path).to eq('/api/firewall/alias/reconfigure')
  end

  it 'allows enough time for OPNsense to finish a synchronous WireGuard apply' do
    response = instance_double(Faraday::Response, status: 200, body: { 'result' => 'ok' }.to_json)
    allow(Faraday).to receive(:new).and_return(conn)
    allow(conn).to receive(:post).and_yield(request).and_return(response)

    described_class.new(config).reconfigure_wireguard

    expect(request.options.timeout).to eq(described_class::WIREGUARD_RECONFIGURE_TIMEOUT)
  end

  it 'returns all WireGuard runtime records' do
    records = [
      { 'if' => 'wg0', 'type' => 'interface', 'public-key' => 'instance-public-key' },
      { 'if' => 'wg0', 'type' => 'peer', 'public-key' => 'peer-public-key' }
    ]
    runtime = stub_request(:get, 'https://opnsense.local/api/wireguard/service/show')
              .with(query: { 'rowCount' => '-1' })
              .to_return(status: 200, body: { 'rows' => records }.to_json)

    result = described_class.new(config).wireguard_runtime

    expect(result).to eq(records)
    expect(runtime).to have_been_requested.once
  end

  it 'lists selectable WireGuard instances and peers' do
    stub_request(:get, 'https://opnsense.local/api/wireguard/server/search_server')
      .with(query: { 'rowCount' => '-1' })
      .to_return(
        status: 200,
        body: {
          'rows' => [
            { 'uuid' => instance_uuid, 'name' => 'z-instance', 'interface' => 'wg1' },
            { 'uuid' => other_instance_uuid, 'name' => 'a-instance', 'interface' => 'wg0' }
          ]
        }.to_json
      )
    stub_request(:get, 'https://opnsense.local/api/wireguard/client/search_client')
      .with(query: { 'rowCount' => '-1' })
      .to_return(
        status: 200,
        body: { 'rows' => [{ 'uuid' => peer_uuid, 'name' => 'proton-peer' }] }.to_json
      )

    result = described_class.new(config).wireguard_targets

    expect(result[:instances].map { |instance| instance[:name] }).to eq(%w[a-instance z-instance])
    expect(result[:peers]).to eq([{ uuid: peer_uuid, name: 'proton-peer' }])
  end
end
