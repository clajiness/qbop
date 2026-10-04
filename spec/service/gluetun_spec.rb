require 'bundler/setup'
Bundler.require(:default)
require 'webmock/rspec'

require_relative '../../service/gluetun'

RSpec.describe Service::Gluetun do # rubocop:disable Metrics/BlockLength
  let(:config) { { gluetun_addr: 'http://gluetun:8000', gluetun_ssl_verify: false } }
  let(:source) { described_class.new(config) }
  let(:endpoint) { 'http://gluetun:8000/v1/portforward' }

  it 'identifies itself as gluetun' do
    expect(source.name).to eq('gluetun')
  end

  [1, 51_820, 65_535].each do |port|
    it "returns the valid integer port #{port}" do
      stub_request(:get, endpoint).to_return(body: JSON.generate(port: port))

      expect(source.current_port).to eq(port)
    end
  end

  it 'accepts the documented single-port response with a matching ports list' do
    stub_request(:get, endpoint).to_return(body: '{"port":51820,"ports":[51820]}')

    expect(source.current_port).to eq(51_820)
  end

  it 'uses X-API-Key instead of Basic credentials when both are configured' do
    config.merge!(gluetun_api_key: 'api-secret', gluetun_user: 'user', gluetun_pass: 'password')
    request = stub_request(:get, endpoint)
              .with(headers: { 'X-API-Key' => 'api-secret' }) { |req| !req.headers.key?('Authorization') }
              .to_return(body: '{"port":51820}')

    expect(source.current_port).to eq(51_820)
    expect(request).to have_been_requested.once
  end

  it 'uses HTTP Basic when only username and password are configured' do
    config.merge!(gluetun_user: 'user', gluetun_pass: 'password', gluetun_api_key: '  ')
    request = stub_request(:get, endpoint)
              .with(basic_auth: %w[user password]) { |req| !req.headers.key?('X-Api-Key') }
              .to_return(body: '{"port":51820}')

    expect(source.current_port).to eq(51_820)
    expect(request).to have_been_requested.once
  end

  it 'makes an unauthenticated request when no credentials are configured' do
    request = stub_request(:get, endpoint).with do |req|
      !req.headers.key?('Authorization') && !req.headers.key?('X-Api-Key')
    end.to_return(body: '{"port":51820}')

    expect(source.current_port).to eq(51_820)
    expect(request).to have_been_requested.once
  end

  [true, false].each do |verify|
    it "configures TLS verification as #{verify} only on its own client" do
      config.merge!(gluetun_addr: 'https://gluetun:8000', gluetun_ssl_verify: verify)
      allow(Faraday).to receive(:new).and_call_original

      source

      expect(Faraday).to have_received(:new).with(
        url: 'https://gluetun:8000', ssl: { verify: verify }, request: { open_timeout: 5, timeout: 10 }
      )
    end
  end

  [0, nil, '12345', 12.5, -1, 65_536, true, [12_345]].each do |port|
    it "rejects an invalid port #{port.inspect}" do
      stub_request(:get, endpoint).to_return(body: JSON.generate(port: port))

      expect { source.current_port }.to raise_error(described_class::PortError, /valid integer port/)
    end
  end

  ['{}', 'null', '[]', '12345', '"12345"'].each do |body|
    it "rejects an unexpected response structure #{body}" do
      stub_request(:get, endpoint).to_return(body: body)

      expect { source.current_port }.to raise_error(described_class::PortError, /valid integer port/)
    end
  end

  [[51_820, 51_821], [], nil, '51820', [51_820.0], [51_821]].each do |ports|
    it "rejects an unsupported or inconsistent ports list #{ports.inspect}" do
      stub_request(:get, endpoint).to_return(body: JSON.generate(port: 51_820, ports: ports))

      expect { source.current_port }.to raise_error(described_class::PortError, /exactly one forwarded port/)
    end
  end

  it 'rejects malformed JSON without exposing its contents' do
    stub_request(:get, endpoint).to_return(body: 'secret-response')

    expect { source.current_port }
      .to raise_error(described_class::PortError, 'Gluetun control API returned malformed JSON')
  end

  [301, 401, 403, 404, 500].each do |status|
    it "rejects HTTP #{status} without exposing the response body" do
      stub_request(:get, endpoint).to_return(status: status, body: 'secret-response')

      expect { source.current_port }
        .to raise_error(described_class::PortError, "Gluetun control API returned HTTP #{status}")
    end
  end

  [Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError].each do |error|
    it "handles #{error} without exposing transport details" do
      stub_request(:get, endpoint).to_raise(error.new('api-secret password'))

      expect { source.current_port }
        .to raise_error(described_class::PortError, "Gluetun control API request failed (#{error})")
    end
  end
end
