require 'bundler/setup'
Bundler.require(:default)

require 'base64'
require_relative '../../service/helpers'
require_relative '../../service/proton_wireguard'

RSpec.describe Service::ProtonWireguard do # rubocop:disable Metrics/BlockLength
  let(:private_key) { Base64.strict_encode64("\x01" * 32) }
  let(:peer_public_key) { Base64.strict_encode64("\x02" * 32) }
  let(:derived_public_key) { Base64.strict_encode64("\x03" * 32) }
  let(:helpers) { instance_double(Service::Helpers, generate_wg_public_key: derived_public_key) }
  let(:config) do
    <<~CONFIG
      [Interface]
      # Moderate NAT = off
      # NAT-PMP (Port Forwarding) = on
      PrivateKey = #{private_key}
      Address = 10.2.0.2/32, 2a07:b944::2:2/128
      DNS = 10.2.0.1
      ListenPort = 51821
      MTU = 1300

      [Peer]
      PublicKey = #{peer_public_key}
      AllowedIPs = 0.0.0.0/0, ::/0
      Endpoint = 192.0.2.10:51820
      PersistentKeepalive = 15
    CONFIG
  end

  it 'parses a ProtonVPN config into OPNsense instance and peer values' do
    result = described_class.new(helpers).import(config)

    expect(helpers).to have_received(:generate_wg_public_key).with(private_key)
    expect(result.keys).to contain_exactly(:instance, :peer)
    expect(result[:instance].keys).to contain_exactly(
      :public_key, :private_key, :dns_servers, :tunnel_addresses, :gateway
    )
    expect(result[:peer].keys).to contain_exactly(
      :public_key, :allowed_ips, :endpoint_address, :endpoint_port
    )
    expect(result[:instance]).to include(
      public_key: derived_public_key,
      private_key: private_key,
      dns_servers: '10.2.0.1',
      tunnel_addresses: '10.2.0.2/32, 2a07:b944::2:2/128',
      gateway: '10.2.0.1'
    )
    expect(result[:peer]).to include(
      public_key: peer_public_key,
      allowed_ips: '0.0.0.0/0, ::/0',
      endpoint_address: '192.0.2.10',
      endpoint_port: 51_820
    )
  end

  it 'rejects a config that does not declare NAT-PMP status' do
    undeclared = config.lines.reject { |line| line.include?('NAT-PMP') }.join

    expect { described_class.new(helpers).import(undeclared) }
      .to raise_error(described_class::ImportError, /must be enabled/)
  end

  it 'rejects a config with port forwarding disabled' do
    disabled = config.sub('NAT-PMP (Port Forwarding) = on', 'NAT-PMP (Port Forwarding) = off')

    expect { described_class.new(helpers).import(disabled) }
      .to raise_error(described_class::ImportError, /must be enabled/)
  end

  it 'rejects a config with moderate NAT enabled' do
    moderate_nat = config.sub('Moderate NAT = off', 'Moderate NAT = on')

    expect { described_class.new(helpers).import(moderate_nat) }
      .to raise_error(described_class::ImportError, /Moderate NAT is incompatible/)
  end

  it 'rejects executable wg-quick settings' do
    executable = config.sub('PrivateKey =', "PostUp = touch /tmp/example\nPrivateKey =")

    expect { described_class.new(helpers).import(executable) }
      .to raise_error(described_class::ImportError, /unsupported Interface setting PostUp/)
  end

  it 'rejects oversized configurations before parsing them' do
    oversized = 'x' * (described_class::MAX_CONFIG_BYTES + 1)

    expect { described_class.new(helpers).import(oversized) }
      .to raise_error(described_class::ImportError, /exceeds/)
  end

  it 'rejects binary input' do
    binary = "\xFF".b

    expect { described_class.new(helpers).import(binary) }
      .to raise_error(described_class::ImportError, /valid UTF-8/)
  end
end
