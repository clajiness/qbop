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

  %i[gluetun_api_key gluetun_user gluetun_pass].each do |setting|
    ["\n", "\r", "\t", "\0", "\u007F", "\u0085"].each do |control|
      it "rejects #{setting} containing #{control.inspect} without exposing credentials" do
        config.merge!(gluetun_user: 'user-secret', gluetun_pass: 'pass-secret')
        config[setting] = "credential-secret#{control}suffix"

        expect { source }.to raise_error(
          described_class::PortError, "#{setting.to_s.upcase} must be a string without control characters"
        ) do |error|
          expect(error.cause).to be_nil
          expect(error.full_message).not_to include('credential-secret', 'user-secret', 'pass-secret')
        end
      end
    end

    it "rejects #{setting} with invalid encoding without exposing credentials" do
      config.merge!(gluetun_user: 'user-secret', gluetun_pass: 'pass-secret')
      config[setting] = "credential-secret\xFF".force_encoding(Encoding::UTF_8)

      expect { source }.to raise_error(described_class::PortError) do |error|
        expect(error.full_message).not_to include('credential-secret', 'user-secret', 'pass-secret')
      end
    end
  end

  [
    'http://url-user:url-secret password@gluetun:8000',
    'http://url-user:url-secret@gluetun:8000/bad path',
    'http://url-user:url-secret@gluetun:badport'
  ].each do |address|
    it "rejects malformed credential-bearing addresses safely: #{address}" do
      config[:gluetun_addr] = address

      expect { source }.to raise_error(
        described_class::PortError, 'Gluetun configuration failed (URI::InvalidURIError)'
      ) do |error|
        expect(error.cause).to be_nil
        expect(error.full_message).not_to include(address, 'url-user', 'url-secret')
      end
    end
  end

  %w[gluetun:8000 ftp://gluetun:8000 http:///control].each do |address|
    it "requires an HTTP(S) base URL with a host: #{address}" do
      config[:gluetun_addr] = address

      expect { source }.to raise_error(described_class::PortError, 'GLUETUN_ADDR must be an HTTP(S) base URL')
    end
  end

  ['?api_key=query-secret', '#fragment-secret', '?', '#'].each do |suffix|
    it "rejects query strings and fragments, including empty ones: #{suffix}" do
      config[:gluetun_addr] = "http://url-user:url-secret@gluetun:8000/control#{suffix}"

      expect { source }.to raise_error(
        described_class::PortError, 'GLUETUN_ADDR must not contain a query string or fragment'
      ) do |error|
        expect(error.full_message).not_to include('url-user', 'url-secret', 'query-secret', 'fragment-secret')
      end
    end
  end

  it 'sanitizes unexpected client initialization errors and removes their causes' do
    allow(Faraday).to receive(:new).and_raise(ArgumentError, 'url-secret api-secret user-secret pass-secret')

    expect { source }.to raise_error(
      described_class::PortError, 'Gluetun configuration failed (ArgumentError)'
    ) do |error|
      expect(error.cause).to be_nil
      expect(error.full_message).not_to include('url-secret', 'api-secret', 'user-secret', 'pass-secret')
    end
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

  ['/control', '/control/'].each do |prefix|
    it "preserves the control server base path #{prefix}" do
      config[:gluetun_addr] = "http://gluetun:8000#{prefix}"
      request = stub_request(:get, 'http://gluetun:8000/control/v1/portforward')
                .to_return(body: '{"port":51820}')

      expect(source.current_port).to eq(51_820)
      expect(request).to have_been_requested.once
    end
  end

  it 'does not send URL-derived Basic authentication alongside an API key' do
    config.merge!(gluetun_addr: 'http://url-user:url-pass@gluetun:8000', gluetun_api_key: 'api-secret')
    request = stub_request(:get, endpoint)
              .with(headers: { 'X-API-Key' => 'api-secret' }) { |req| !req.headers.key?('Authorization') }
              .to_return(body: '{"port":51820}')

    expect(source.current_port).to eq(51_820)
    expect(request).to have_been_requested.once
  end

  it 'removes URL userinfo before passing the base URL to Faraday' do
    config[:gluetun_addr] = 'http://url-user:url-secret@gluetun:8000/control'
    allow(Faraday).to receive(:new).and_call_original

    source

    expect(Faraday).to have_received(:new).with(
      url: 'http://gluetun:8000/control', ssl: { verify: false }, request: { open_timeout: 5, timeout: 10 }
    )
  end

  it 'uses configured Basic credentials instead of URL-derived credentials' do
    config.merge!(gluetun_addr: 'http://url-user:url-pass@gluetun:8000',
                  gluetun_user: 'user', gluetun_pass: 'password')
    request = stub_request(:get, endpoint)
              .with(basic_auth: %w[user password])
              .to_return(body: '{"port":51820}')

    expect(source.current_port).to eq(51_820)
    expect(request).to have_been_requested.once
  end

  it 'stays unauthenticated when only URL-derived credentials are present' do
    config[:gluetun_addr] = 'http://url-user:url-pass@gluetun:8000'
    request = stub_request(:get, endpoint)
              .with { |req| !req.headers.key?('Authorization') }
              .to_return(body: '{"port":51820}')

    expect(source.current_port).to eq(51_820)
    expect(request).to have_been_requested.once
  end

  it 'uses X-API-Key instead of Basic credentials when both are configured' do
    config.merge!(gluetun_api_key: 'api-secret', gluetun_user: 'user', gluetun_pass: 'password')
    request = stub_request(:get, endpoint)
              .with(headers: { 'X-API-Key' => 'api-secret' }) { |req| !req.headers.key?('Authorization') }
              .to_return(body: '{"port":51820}')

    expect(source.current_port).to eq(51_820)
    expect(request).to have_been_requested.once
  end

  it 'preserves API-key precedence when unused Basic credentials contain control characters' do
    config.merge!(gluetun_api_key: 'api-secret', gluetun_user: "user-secret\n", gluetun_pass: "pass-secret\0")
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
      .to raise_error(described_class::PortError, 'Gluetun control API returned malformed JSON') do |error|
        expect(error.cause).to be_nil
        expect(error.full_message).not_to include('secret-response')
      end
  end

  [301, 401, 403, 404, 500].each do |status|
    it "rejects HTTP #{status} without exposing the response body" do
      stub_request(:get, endpoint).to_return(status: status, body: 'secret-response')

      expect { source.current_port }
        .to raise_error(described_class::PortError, "Gluetun control API returned HTTP #{status}")
    end
  end

  [Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError, ArgumentError].each do |error|
    it "handles #{error} without exposing transport details" do
      stub_request(:get, endpoint).to_raise(error.new('api-secret password'))

      expect { source.current_port }
        .to raise_error(described_class::PortError, "Gluetun control API request failed (#{error})") do |raised|
          expect(raised.cause).to be_nil
          expect(raised.full_message).not_to include('api-secret', 'password')
        end
    end
  end

  it 'propagates an existing PortError without wrapping it' do
    error = described_class::PortError.new('Gluetun response did not contain a valid integer port in 1-65535')
    stub_request(:get, endpoint).to_raise(error)

    expect { source.current_port }.to raise_error(described_class::PortError) do |raised|
      expect(raised).to equal(error)
    end
  end
end
