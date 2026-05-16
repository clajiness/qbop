require 'bundler/setup'
Bundler.require(:default)

require_relative '../../service/opnsense'

RSpec.describe Service::Opnsense do # rubocop:disable Metrics/BlockLength
  let(:request_class) do
    Class.new(Struct.new(:headers, :body, :url_path)) do
      def initialize
        super({}, nil, nil)
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
end
