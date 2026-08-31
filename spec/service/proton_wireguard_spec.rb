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
      DNS = 10.2.0.1, 2a07:b944::2:1
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
    expect(result.keys).to contain_exactly(:instance, :peer, :metadata)
    expect(result[:instance].keys).to contain_exactly(:public_key, :private_key, :tunnel_addresses)
    expect(result[:peer].keys).to contain_exactly(
      :public_key, :allowed_ips, :endpoint_address, :endpoint_port
    )
    expect(result[:instance]).to include(
      public_key: derived_public_key,
      private_key: private_key,
      tunnel_addresses: '10.2.0.2/32, 2a07:b944::2:2/128'
    )
    expect(result[:peer]).to include(
      public_key: peer_public_key,
      allowed_ips: '0.0.0.0/0, ::/0',
      endpoint_address: '192.0.2.10',
      endpoint_port: 51_820
    )
    expect(result[:instance]).not_to have_key(:dns)
    expect(result[:metadata]).to eq({})
  end

  it 'parses a bracketed IPv6 endpoint' do
    ipv6_config = config.sub('192.0.2.10:51820', '[2001:db8::1]:51820')

    result = described_class.new(helpers).import(ipv6_config)

    expect(result[:peer]).to include(endpoint_address: '2001:db8::1', endpoint_port: 51_820)
  end

  it 'parses a hostname endpoint' do
    hostname_config = config.sub('192.0.2.10:51820', 'vpn.example.com:51820')

    result = described_class.new(helpers).import(hostname_config)

    expect(result[:peer]).to include(endpoint_address: 'vpn.example.com', endpoint_port: 51_820)
  end

  it 'rejects IPv4 and IPv6 endpoint addresses containing CIDR prefixes' do
    ipv4_cidr = config.sub('192.0.2.10:51820', '1.2.3.4/24:51820')
    ipv6_cidr = config.sub('192.0.2.10:51820', '[2001:db8::1/64]:51820')

    aggregate_failures do
      expect { described_class.new(helpers).import(ipv4_cidr) }
        .to raise_error(described_class::ImportError, /Peer endpoint address is invalid/)
      expect { described_class.new(helpers).import(ipv6_cidr) }
        .to raise_error(described_class::ImportError, /Peer endpoint address is invalid/)
    end
  end

  it 'parses a config without DNS' do
    result = described_class.new(helpers).import(
      config.sub("DNS = 10.2.0.1, 2a07:b944::2:1\n", '')
    )

    expect(result[:instance]).to include(tunnel_addresses: '10.2.0.2/32, 2a07:b944::2:2/128')
    expect(result[:instance]).not_to have_key(:dns)
  end

  it 'tolerates unusual DNS values without consuming them' do
    unusual_dns = config.sub(
      'DNS = 10.2.0.1, 2a07:b944::2:1',
      'DNS = proton-dns, not-an-ip, 2001:db8::/64'
    )

    result = described_class.new(helpers).import(unusual_dns)

    expect(result[:instance]).not_to have_key(:dns)
  end

  it 'still requires every consumed WireGuard setting' do
    required_settings = {
      "PrivateKey = #{private_key}\n" => /missing PrivateKey in \[Interface\]/,
      "Address = 10.2.0.2/32, 2a07:b944::2:2/128\n" => /missing Address in \[Interface\]/,
      "PublicKey = #{peer_public_key}\n" => /missing PublicKey in \[Peer\]/,
      "AllowedIPs = 0.0.0.0/0, ::/0\n" => /missing AllowedIPs in \[Peer\]/,
      "Endpoint = 192.0.2.10:51820\n" => /missing Endpoint in \[Peer\]/
    }

    aggregate_failures do
      required_settings.each do |line, message|
        expect { described_class.new(helpers).import(config.sub(line, '')) }
          .to raise_error(described_class::ImportError, message)
      end
    end
  end

  it 'continues validating every consumed WireGuard setting' do
    invalid_settings = {
      config.sub(private_key, 'invalid') => /Interface private key is not a valid wireguard key/,
      config.sub('Address = 10.2.0.2/32, 2a07:b944::2:2/128', 'Address = invalid') =>
        /Interface address is invalid/,
      config.sub(peer_public_key, 'invalid') => /Peer public key is not a valid wireguard key/,
      config.sub('AllowedIPs = 0.0.0.0/0, ::/0', 'AllowedIPs = invalid') =>
        /Peer allowed IPs is invalid/,
      config.sub('Endpoint = 192.0.2.10:51820', 'Endpoint = invalid') =>
        /Peer endpoint must include an address and port/
    }

    aggregate_failures do
      invalid_settings.each do |invalid_config, message|
        expect { described_class.new(helpers).import(invalid_config) }
          .to raise_error(described_class::ImportError, message)
      end
    end
  end

  it 'continues enforcing WireGuard section structure' do
    duplicate_peer = config.sub('[Peer]', "[Peer]\n[Peer]")
    unsupported_section = config.sub('[Peer]', '[Unknown]')

    aggregate_failures do
      expect { described_class.new(helpers).import(duplicate_peer) }
        .to raise_error(described_class::ImportError, /exactly one \[Peer\] section/)
      expect { described_class.new(helpers).import(unsupported_section) }
        .to raise_error(described_class::ImportError, /unsupported wireguard section \[Unknown\]/)
    end
  end

  it 'derives Proton_SE108 from an SE server comment' do
    result = described_class.new(helpers).import(config.sub("[Peer]\n", "[Peer]\n# SE#108\n"))

    identifier = result.dig(:metadata, :proton_server_identifier)
    expect(identifier).to eq('SE#108')
    expect(described_class.peer_name_for(identifier)).to eq('Proton_SE108')
  end

  it 'derives Proton_NO56 from a NO server comment' do
    result = described_class.new(helpers).import(config.sub("[Peer]\n", "[Peer]\n# NO#56\n"))

    identifier = result.dig(:metadata, :proton_server_identifier)
    expect(identifier).to eq('NO#56')
    expect(described_class.peer_name_for(identifier)).to eq('Proton_NO56')
  end

  it 'derives Proton_US-IL661 while preserving the server prefix hyphen' do
    result = described_class.new(helpers).import(config.sub("[Peer]\n", "[Peer]\n# US-IL#661\n"))

    identifier = result.dig(:metadata, :proton_server_identifier)
    expect(identifier).to eq('US-IL#661')
    expect(described_class.peer_name_for(identifier)).to eq('Proton_US-IL661')
  end

  it 'does not treat the Proton IPv6 explanatory comment as server metadata' do
    comment = '# Uncomment the following line (delete the # symbol) to connect to Proton VPN using IPv6.'
    result = described_class.new(helpers).import(config.sub("[Peer]\n", "[Peer]\n#{comment}\n"))

    expect(result[:metadata]).to eq({})
  end

  it 'validates a generated peer name against the OPNsense length restriction' do
    identifier = "#{'A' * 57}#1"

    expect { described_class.peer_name_for(identifier) }
      .to raise_error(described_class::ImportError, /not valid for opnsense/)
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
