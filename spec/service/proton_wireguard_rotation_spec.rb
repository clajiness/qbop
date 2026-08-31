require 'bundler/setup'
Bundler.require(:default)

require 'tempfile'
require 'webmock/rspec'

require_relative '../../service/proton_wireguard_rotation'

RSpec.describe Service::ProtonWireguardRotation do # rubocop:disable Metrics/BlockLength
  let(:config) do
    {
      opnsense_interface_addr: 'https://opnsense.local',
      opnsense_api_key: 'test_api_key',
      opnsense_api_secret: 'test_api_secret',
      opnsense_ssl_verify: false
    }
  end
  let(:instance_uuid) { '11111111-1111-4111-8111-111111111111' }
  let(:peer_uuid) { '22222222-2222-4222-8222-222222222222' }
  let(:other_instance_uuid) { '33333333-3333-4333-8333-333333333333' }
  let(:other_peer_uuid) { '44444444-4444-4444-8444-444444444444' }
  let(:lock_file) { Tempfile.new('qbop-wireguard-rotation-spec') }
  let(:wireguard) do
    {
      instance: {
        public_key: 'new-instance-public-key',
        private_key: 'new-instance-private-key',
        tunnel_addresses: '10.2.0.2/32, 2a07:b944::2:2/128'
      },
      peer: {
        public_key: 'new-peer-public-key',
        allowed_ips: '0.0.0.0/0, ::/0',
        endpoint_address: '192.0.2.10',
        endpoint_port: 51_820
      }
    }
  end
  let(:renamed_wireguard) do
    wireguard.merge(metadata: { proton_server_identifier: 'US-IL#661' })
  end
  let(:new_instance) do
    {
      'pubkey' => 'new-instance-public-key',
      'privkey' => 'new-instance-private-key',
      'tunneladdress' => '10.2.0.2/32'
    }
  end
  let(:new_peer) do
    {
      'pubkey' => 'new-peer-public-key',
      'tunneladdress' => '0.0.0.0/0',
      'serveraddress' => '192.0.2.10',
      'serverport' => '51820',
      'servers' => instance_uuid
    }
  end
  let(:old_instance) do
    {
      'pubkey' => 'old-instance-public-key',
      'privkey' => 'old-instance-private-key',
      'tunneladdress' => '10.3.0.2/32'
    }
  end
  let(:old_peer) do
    {
      'name' => 'proton-peer',
      'pubkey' => 'old-peer-public-key',
      'tunneladdress' => '0.0.0.0/0',
      'serveraddress' => '198.51.100.10',
      'serverport' => '51820',
      'servers' => instance_uuid
    }
  end

  after { lock_file.close! }

  def selected_options(*values)
    values.to_h { |value| [value, { 'value' => value, 'selected' => 1 }] }
  end

  def instance_record( # rubocop:disable Metrics/MethodLength
    enabled: '1', tunnel_addresses: ['10.3.0.2/32'], peers: [peer_uuid]
  )
    {
      'name' => 'proton-instance',
      'enabled' => enabled,
      'pubkey' => 'old-instance-public-key',
      'privkey' => 'old-instance-private-key',
      'port' => '51821',
      'dns' => {},
      'tunneladdress' => selected_options(*tunnel_addresses),
      'disableroutes' => '1',
      'gateway' => '10.100.100.100',
      'mtu' => '1420',
      'interface' => 'wg0',
      'peers' => selected_options(*peers)
    }
  end

  def peer_record(instances: [instance_uuid], allowed_ips: ['0.0.0.0/0'])
    {
      'name' => 'proton-peer',
      'pubkey' => 'old-peer-public-key',
      'tunneladdress' => selected_options(*allowed_ips),
      'serveraddress' => '198.51.100.10',
      'serverport' => '51820',
      'servers' => selected_options(*instances),
      'keepalive' => '25',
      'psk' => 'preserved-preshared-key'
    }
  end

  def runtime_records(instance_public_key: 'old-instance-public-key', peer_public_key: 'old-peer-public-key')
    [
      { 'if' => 'wg0', 'type' => 'interface', 'public-key' => instance_public_key },
      { 'if' => 'wg0', 'type' => 'peer', 'public-key' => peer_public_key }
    ]
  end

  def stub_pair( # rubocop:disable Metrics/ParameterLists
    opnsense,
    enabled: '1',
    instances: [instance_uuid],
    peers: [peer_uuid],
    instance_addresses: ['10.3.0.2/32'],
    peer_allowed_ips: ['0.0.0.0/0']
  )
    allow(opnsense).to receive(:validate_wireguard_config)
    allow(opnsense).to receive(:wireguard_instance).with(instance_uuid).and_return(
      instance_record(enabled: enabled, tunnel_addresses: instance_addresses, peers: peers)
    )
    allow(opnsense).to receive(:wireguard_peer).with(peer_uuid).and_return(
      peer_record(instances: instances, allowed_ips: peer_allowed_ips)
    )
  end

  def rotation_for(opnsense)
    described_class.new(config, opnsense: opnsense, lock_path: lock_file.path)
  end

  it 'preserves the dedicated association and exact rotation API order' do # rubocop:disable Metrics/BlockLength
    stub_request(:get, "https://opnsense.local/api/wireguard/server/get_server/#{instance_uuid}")
      .to_return(status: 200, body: { 'server' => instance_record }.to_json)
    stub_request(:get, "https://opnsense.local/api/wireguard/client/get_client/#{peer_uuid}")
      .to_return(status: 200, body: { 'client' => peer_record }.to_json)
    events = []
    saved = { status: 200, body: { 'result' => 'saved' }.to_json }
    instance_endpoint = "https://opnsense.local/api/wireguard/server/set_server/#{instance_uuid}"
    peer_endpoint = "https://opnsense.local/api/wireguard/client/set_client/#{peer_uuid}"

    disable = stub_request(:post, instance_endpoint).with(body: { 'server' => { 'enabled' => '0' } }.to_json)
    disable.to_return do
      events << :disable
      saved
    end
    peer = stub_request(:post, peer_endpoint).with do |request|
      JSON.parse(request.body) == { 'client' => new_peer }
    end
    peer.to_return do
      events << :update_peer
      saved
    end
    instance = stub_request(:post, instance_endpoint).with(body: { 'server' => new_instance }.to_json)
    instance.to_return do
      events << :update_instance
      saved
    end
    enable = stub_request(:post, instance_endpoint).with(body: { 'server' => { 'enabled' => '1' } }.to_json)
    enable.to_return do
      events << :enable
      saved
    end
    apply = stub_request(:post, 'https://opnsense.local/api/wireguard/service/reconfigure')
    apply.to_return do
      events << :apply
      { status: 200, body: { 'result' => 'ok' }.to_json }
    end
    runtime_check = 0
    runtime = stub_request(:get, 'https://opnsense.local/api/wireguard/service/show')
              .with(query: { 'rowCount' => '-1' })
    runtime.to_return do
      runtime_check += 1
      events << (runtime_check == 1 ? :verify_stopped : :verify_active)
      records = if runtime_check == 1
                  []
                else
                  runtime_records(
                    instance_public_key: 'new-instance-public-key',
                    peer_public_key: 'new-peer-public-key'
                  )
                end
      { status: 200, body: { 'rows' => records }.to_json }
    end

    result = described_class.new(config, lock_path: lock_file.path).rotate(
      wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid
    )

    expect(result).to eq(instance_name: 'proton-instance', peer_name: 'proton-peer')
    expect(events).to eq(
      %i[disable apply verify_stopped update_peer update_instance apply enable apply verify_active]
    )
    expect(disable).to have_been_requested.once
    expect(peer).to have_been_requested.once
    expect(instance).to have_been_requested.once
    expect(enable).to have_been_requested.once
    expect(apply).to have_been_requested.times(3)
    expect(runtime).to have_been_requested.times(2)
  end

  it 'keeps both address families when the adopted instance and peer are dual-stack' do # rubocop:disable Metrics/BlockLength
    opnsense = instance_double(Service::Opnsense)
    stub_pair(
      opnsense,
      instance_addresses: ['10.3.0.2/32', '2001:db8::2/128'],
      peer_allowed_ips: ['0.0.0.0/0', '::/0']
    )
    allow(opnsense).to receive(:save_wireguard_instance)
    allow(opnsense).to receive(:reconfigure_wireguard)
    allow(opnsense).to receive(:wireguard_runtime).and_return(
      [],
      runtime_records(
        instance_public_key: 'new-instance-public-key',
        peer_public_key: 'new-peer-public-key'
      )
    )
    expect(opnsense).to receive(:save_wireguard_peer).with(
      peer_uuid, new_peer.merge('tunneladdress' => '0.0.0.0/0,::/0')
    )
    expect(opnsense).to receive(:save_wireguard_instance).with(
      instance_uuid,
      new_instance.merge('tunneladdress' => '10.2.0.2/32,2a07:b944::2:2/128')
    )

    result = rotation_for(opnsense).rotate(
      wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid
    )

    expect(result).to eq(instance_name: 'proton-instance', peer_name: 'proton-peer')
  end

  it 'rejects a Proton config missing an instance address family before mutation' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense, instance_addresses: ['10.3.0.2/32', '2001:db8::2/128'])
    ipv4_wireguard = wireguard.merge(
      instance: wireguard.fetch(:instance).merge(tunnel_addresses: '10.2.0.2/32')
    )
    expect(opnsense).not_to receive(:save_wireguard_instance)
    expect(opnsense).not_to receive(:save_wireguard_peer)
    expect(opnsense).not_to receive(:reconfigure_wireguard)

    expect do
      rotation_for(opnsense).rotate(
        ipv4_wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid
      )
    end.to raise_error(described_class::Error, /missing IPv6.*instance tunnel addresses/)
  end

  it 'rejects a Proton config missing a peer address family before mutation' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense, peer_allowed_ips: ['0.0.0.0/0', '::/0'])
    ipv4_wireguard = wireguard.merge(
      peer: wireguard.fetch(:peer).merge(allowed_ips: '0.0.0.0/0')
    )
    expect(opnsense).not_to receive(:save_wireguard_instance)
    expect(opnsense).not_to receive(:save_wireguard_peer)
    expect(opnsense).not_to receive(:reconfigure_wireguard)

    expect do
      rotation_for(opnsense).rotate(
        ipv4_wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid
      )
    end.to raise_error(described_class::Error, /missing IPv6.*peer allowed IPs/)
  end

  it 'adds the generated name only when peer renaming is selected' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    allow(opnsense).to receive(:wireguard_runtime).and_return(
      [],
      runtime_records(
        instance_public_key: 'new-instance-public-key',
        peer_public_key: 'new-peer-public-key'
      )
    )
    allow(opnsense).to receive(:save_wireguard_instance)
    allow(opnsense).to receive(:reconfigure_wireguard)
    expect(opnsense).to receive(:save_wireguard_peer).with(
      peer_uuid, new_peer.merge('name' => 'Proton_US-IL661')
    )

    result = rotation_for(opnsense).rotate(
      renamed_wireguard,
      instance_uuid: instance_uuid,
      peer_uuid: peer_uuid,
      rename_peer: true
    )

    expect(result).to eq(instance_name: 'proton-instance', peer_name: 'Proton_US-IL661')
  end

  it 'restores the original peer name after a renamed peer was written' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    allow(opnsense).to receive(:wireguard_runtime).and_return([], runtime_records)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '0').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_peer).with(
      peer_uuid, new_peer.merge('name' => 'Proton_US-IL661')
    ).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(
      instance_uuid, new_instance
    ).ordered.and_raise(Faraday::TimeoutError)
    expect(opnsense).to receive(:save_wireguard_peer).with(peer_uuid, old_peer).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, old_instance).ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '1').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered

    expect do
      rotation_for(opnsense).rotate(
        renamed_wireguard,
        instance_uuid: instance_uuid,
        peer_uuid: peer_uuid,
        rename_peer: true
      )
    end.to raise_error(described_class::Error, /rotation failed.*rollback completed/)
  end

  it 'rejects invalid selections before reading OPNsense' do
    opnsense = instance_double(Service::Opnsense, validate_wireguard_config: nil)

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: 'new', peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /Instance selection is invalid/)
  end

  it 'rejects an invalid generated peer name before contacting OPNsense' do
    opnsense = instance_double(Service::Opnsense)
    invalid_name = wireguard.merge(
      metadata: { proton_server_identifier: "#{'A' * 57}#1" }
    )

    expect do
      rotation_for(opnsense).rotate(
        invalid_name,
        instance_uuid: instance_uuid,
        peer_uuid: peer_uuid,
        rename_peer: true
      )
    end.to raise_error(described_class::Error, /generated name is not valid for OPNsense/)
  end

  it 'rejects a disabled instance before writing' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense, enabled: '0')

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /must be enabled/)
  end

  it 'rejects a peer shared with another instance before mutation' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense, instances: [instance_uuid, other_instance_uuid])
    expect(opnsense).not_to receive(:save_wireguard_instance)
    expect(opnsense).not_to receive(:save_wireguard_peer)
    expect(opnsense).not_to receive(:reconfigure_wireguard)

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /must be dedicated to each other/)
  end

  it 'rejects an instance containing another peer before mutation' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense, peers: [peer_uuid, other_peer_uuid])
    expect(opnsense).not_to receive(:save_wireguard_instance)
    expect(opnsense).not_to receive(:save_wireguard_peer)
    expect(opnsense).not_to receive(:reconfigure_wireguard)

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /must be dedicated to each other/)
  end

  it 'rejects an instance and peer that are both shared before mutation' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(
      opnsense,
      instances: [instance_uuid, other_instance_uuid],
      peers: [peer_uuid, other_peer_uuid]
    )
    expect(opnsense).not_to receive(:save_wireguard_instance)
    expect(opnsense).not_to receive(:save_wireguard_peer)
    expect(opnsense).not_to receive(:reconfigure_wireguard)

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /must be dedicated to each other/)
  end

  it 'rejects a concurrent rotation before reading OPNsense' do
    opnsense = instance_double(Service::Opnsense, validate_wireguard_config: nil)

    File.open(lock_file.path, File::RDWR) do |held_lock|
      held_lock.flock(File::LOCK_EX)
      expect do
        rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
      end.to raise_error(described_class::Busy, /already in progress/)
    end
  end

  it 'restores the original enabled state when the disable response is lost' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    expect(opnsense).to receive(:save_wireguard_instance).with(
      instance_uuid, 'enabled' => '0'
    ).ordered.and_raise(Faraday::TimeoutError)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '1').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    allow(opnsense).to receive(:wireguard_runtime).and_return(runtime_records)

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /rotation failed.*rollback completed/)
  end

  it 're-enables and applies when the first disabled-state apply fails' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '0').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered.and_raise(Faraday::TimeoutError)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '1').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    allow(opnsense).to receive(:wireguard_runtime).and_return(runtime_records)

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /rotation failed/)
  end

  it 'restores the peer, applies while disabled, then re-enables when the peer write fails' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    allow(opnsense).to receive(:wireguard_runtime).and_return([], runtime_records)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '0').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_peer).with(
      peer_uuid, new_peer
    ).ordered.and_raise(Faraday::TimeoutError)
    expect(opnsense).to receive(:save_wireguard_peer).with(peer_uuid, old_peer).ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '1').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /rotation failed/)
  end

  it 'restores peer before instance after both records may have changed' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    allow(opnsense).to receive(:wireguard_runtime).and_return([], runtime_records)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '0').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_peer).with(peer_uuid, new_peer).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(
      instance_uuid, new_instance
    ).ordered.and_raise(Faraday::TimeoutError)
    expect(opnsense).to receive(:save_wireguard_peer).with(peer_uuid, old_peer).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, old_instance).ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '1').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /rotation failed/)
  end

  it 'reports an incomplete rollback when restoring a changed record fails' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    allow(opnsense).to receive(:wireguard_runtime).and_return([], runtime_records)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '0').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_peer).with(
      peer_uuid, new_peer
    ).ordered.and_raise(Faraday::TimeoutError)
    expect(opnsense).to receive(:save_wireguard_peer).with(
      peer_uuid, old_peer
    ).ordered.and_raise(Faraday::TimeoutError)
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '1').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /rollback incomplete: peer restore failed/)
  end

  it 'restores both records and applies before re-enabling when the middle apply fails' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    allow(opnsense).to receive(:wireguard_runtime).and_return([], runtime_records)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '0').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_peer).with(peer_uuid, new_peer).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, new_instance).ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered.and_raise(Faraday::TimeoutError)
    expect(opnsense).to receive(:save_wireguard_peer).with(peer_uuid, old_peer).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, old_instance).ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '1').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /rotation failed/)
  end

  it 'does not restore records when rollback cannot confirm the instance stopped' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '0').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:wireguard_runtime).ordered.and_return([])
    expect(opnsense).to receive(:save_wireguard_peer).with(peer_uuid, new_peer).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, new_instance).ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '1').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered.and_raise(Faraday::TimeoutError)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '0').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:wireguard_runtime).ordered.and_return(
      runtime_records(instance_public_key: 'new-instance-public-key', peer_public_key: 'new-peer-public-key')
    )
    expect(opnsense).not_to receive(:save_wireguard_peer).with(peer_uuid, old_peer)
    expect(opnsense).not_to receive(:save_wireguard_instance).with(instance_uuid, old_instance)

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /rollback incomplete: disabled state verification failed.*still active/)
  end

  it 'aborts before configuration writes when the disabled instance remains active' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '0').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:wireguard_runtime).ordered.and_return(runtime_records)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '1').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:wireguard_runtime).ordered.and_return(runtime_records)
    expect(opnsense).not_to receive(:save_wireguard_peer)
    expect(opnsense).not_to receive(:save_wireguard_instance).with(instance_uuid, new_instance)

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, %r{still active after disable/apply.*rollback completed})
  end

  it 'rolls back when the imported runtime keys are not active' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    allow(opnsense).to receive(:save_wireguard_instance)
    allow(opnsense).to receive(:save_wireguard_peer)
    allow(opnsense).to receive(:reconfigure_wireguard)
    allow(opnsense).to receive(:wireguard_runtime).and_return(
      [],
      runtime_records(instance_public_key: 'unexpected-instance-key', peer_public_key: 'unexpected-peer-key'),
      [],
      runtime_records
    )

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /not active with the imported keys.*rollback completed/)

    expect(opnsense).to have_received(:save_wireguard_peer).with(peer_uuid, old_peer)
    expect(opnsense).to have_received(:save_wireguard_instance).with(instance_uuid, old_instance)
  end

  it 'rolls back safely when the final re-enable write response is ambiguous' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '0').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:wireguard_runtime).ordered.and_return([])
    expect(opnsense).to receive(:save_wireguard_peer).with(peer_uuid, new_peer).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, new_instance).ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(
      instance_uuid, 'enabled' => '1'
    ).ordered.and_raise(Faraday::TimeoutError)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '0').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:wireguard_runtime).ordered.and_return([])
    expect(opnsense).to receive(:save_wireguard_peer).with(peer_uuid, old_peer).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, old_instance).ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '1').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    expect(opnsense).to receive(:wireguard_runtime).ordered.and_return(runtime_records)

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /rotation failed.*rollback completed/)
  end

  it 'reports rollback incomplete when the restored runtime keys are not active' do
    opnsense = instance_double(Service::Opnsense)
    stub_pair(opnsense)
    expect(opnsense).to receive(:save_wireguard_instance).with(
      instance_uuid, 'enabled' => '0'
    ).ordered.and_raise(Faraday::TimeoutError)
    expect(opnsense).to receive(:save_wireguard_instance).with(instance_uuid, 'enabled' => '1').ordered
    expect(opnsense).to receive(:reconfigure_wireguard).ordered
    allow(opnsense).to receive(:wireguard_runtime).and_return([])

    expect do
      rotation_for(opnsense).rotate(wireguard, instance_uuid: instance_uuid, peer_uuid: peer_uuid)
    end.to raise_error(described_class::Error, /rollback incomplete: original runtime state verification failed/)
  end
end
