require 'bundler/setup'
Bundler.require(:default)

require_relative '../../service/helpers'
require_relative '../../service/port_source'

RSpec.describe Service::PortSource do # rubocop:disable Metrics/BlockLength
  let(:config) { { proton_gateway: '10.7.0.1', loop_freq: 45 } }
  let(:helpers) { instance_double(Service::Helpers, env_variables: config) }
  let(:source) { described_class.build(helpers, config) }
  let(:success_status) { instance_double(Process::Status, success?: true) }
  let(:failed_status) { instance_double(Process::Status, success?: false) }
  let(:udp_output) { 'Mapped public port 54321 protocol UDP' }
  let(:tcp_output) { 'Mapped public port 54321 protocol TCP' }

  def stub_mapping(protocol, stdout:, stderr: '', status: success_status, timeout: '40')
    allow(Open3).to receive(:capture3)
      .with('timeout', timeout, 'natpmpc', '-a', '1', '0', protocol, '60', '-g', config[:proton_gateway])
      .and_return([stdout, stderr, status])
  end

  it 'builds Proton without a source selection setting' do
    expect(source).to be_a(Service::Proton)
  end

  it 'returns an integer port from matching UDP and TCP mappings using the configured gateway' do
    stub_mapping('udp', stdout: udp_output)
    stub_mapping('tcp', stdout: tcp_output)

    expect(source.current_port).to eq(54_321)
    expect(Open3).to have_received(:capture3)
      .with('timeout', '40', 'natpmpc', '-a', '1', '0', 'udp', '60', '-g', '10.7.0.1').ordered
    expect(Open3).to have_received(:capture3)
      .with('timeout', '40', 'natpmpc', '-a', '1', '0', 'tcp', '60', '-g', '10.7.0.1').ordered
  end

  it 'preserves the minimum command timeout' do
    config[:loop_freq] = 5
    stub_mapping('udp', stdout: udp_output, timeout: '5')
    stub_mapping('tcp', stdout: tcp_output, timeout: '5')

    expect(source.current_port).to eq(54_321)
  end

  it 'propagates UDP failures and skips the TCP command' do
    stub_mapping('udp', stdout: '', stderr: 'udp failed', status: failed_status)

    expect { source.current_port }
      .to raise_error(Service::Proton::MappingError, 'UDP NAT-PMP command failed: udp failed')
    expect(Open3).to have_received(:capture3).once
  end

  it 'propagates TCP failures after a successful UDP mapping' do
    stub_mapping('udp', stdout: udp_output)
    stub_mapping('tcp', stdout: tcp_output, status: failed_status)

    expect { source.current_port }
      .to raise_error(Service::Proton::MappingError, 'TCP NAT-PMP command failed')
  end

  it 'rejects mismatched UDP and TCP ports' do
    stub_mapping('udp', stdout: udp_output)
    stub_mapping('tcp', stdout: 'Mapped public port 54322 protocol TCP')

    expect { source.current_port }
      .to raise_error(Service::Proton::MappingError, 'UDP and TCP NAT-PMP ports do not match (54321 and 54322)')
  end

  it 'preserves command stderr validation' do
    stub_mapping('udp', stdout: udp_output)
    stub_mapping('tcp', stdout: tcp_output, stderr: 'mapping error')

    expect { source.current_port }
      .to raise_error(Service::Proton::MappingError, 'TCP NAT-PMP command reported an error: mapping error')
  end

  [
    'unexpected output',
    'Mapped public port 1023 protocol TCP',
    'Mapped public port 65536 protocol TCP'
  ].each do |output|
    it "rejects malformed or invalid mapped ports: #{output}" do
      stub_mapping('udp', stdout: udp_output)
      stub_mapping('tcp', stdout: output)

      expect { source.current_port }
        .to raise_error(Service::Proton::MappingError, 'TCP NAT-PMP response did not contain a valid mapped port')
    end
  end
end
