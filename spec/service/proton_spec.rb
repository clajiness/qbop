require 'bundler/setup'
Bundler.require(:default)

require_relative '../../service/proton'

RSpec.describe Service::Proton do # rubocop:disable Metrics/BlockLength
  let(:helpers) { double('helpers', env_variables: { loop_freq: 45 }) }
  let(:udp_status) { instance_double(Process::Status, success?: true) }
  let(:tcp_status) { instance_double(Process::Status, success?: true) }

  describe '#natpmpc' do
    it 'runs UDP and TCP natpmpc commands with timeout arguments' do
      allow(Open3).to receive(:capture3)
        .with('timeout', '40', 'natpmpc', '-a', '1', '0', 'udp', '60', '-g', '10.2.0.1')
        .and_return(['udp output', '', udp_status])
      allow(Open3).to receive(:capture3)
        .with('timeout', '40', 'natpmpc', '-a', '1', '0', 'tcp', '60', '-g', '10.2.0.1')
        .and_return(['tcp output', '', tcp_status])

      result = described_class.new(helpers).natpmpc('10.2.0.1')

      expect(result).to eq(
        udp: { stdout: 'udp output', stderr: '', status: udp_status },
        tcp: { stdout: 'tcp output', stderr: '', status: tcp_status }
      )
    end

    it 'does not run TCP natpmpc when UDP fails' do
      failed_status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3)
        .with('timeout', '40', 'natpmpc', '-a', '1', '0', 'udp', '60', '-g', '10.2.0.1')
        .and_return(['', 'udp failed', failed_status])

      result = described_class.new(helpers).natpmpc('10.2.0.1')

      expect(Open3).to have_received(:capture3).once
      expect(result).to eq(
        udp: { stdout: '', stderr: 'udp failed', status: failed_status },
        tcp: { stdout: '', stderr: '', status: nil }
      )
    end
  end

  describe '#forwarded_port' do # rubocop:disable Metrics/BlockLength
    def command_result(protocol, port:, status:, stderr: '')
      { stdout: "Mapped public port #{port} protocol #{protocol}", stderr: stderr, status: status }
    end

    it 'accepts successful matching UDP and TCP mappings' do
      response = {
        udp: command_result('UDP', port: 54_321, status: udp_status),
        tcp: command_result('TCP', port: 54_321, status: tcp_status)
      }

      expect(described_class.new(helpers).forwarded_port(response)).to eq(54_321)
    end

    it 'rejects a TCP command failure after UDP succeeds' do
      failed_status = instance_double(Process::Status, success?: false)
      response = {
        udp: command_result('UDP', port: 54_321, status: udp_status),
        tcp: command_result('TCP', port: 54_321, status: failed_status)
      }

      expect { described_class.new(helpers).forwarded_port(response) }
        .to raise_error(described_class::MappingError, 'TCP NAT-PMP command failed')
    end

    it 'rejects a UDP command failure even if the TCP result succeeded' do
      failed_status = instance_double(Process::Status, success?: false)
      response = {
        udp: command_result('UDP', port: 54_321, status: failed_status),
        tcp: command_result('TCP', port: 54_321, status: tcp_status)
      }

      expect { described_class.new(helpers).forwarded_port(response) }
        .to raise_error(described_class::MappingError, 'UDP NAT-PMP command failed')
    end

    it 'rejects mismatched UDP and TCP ports' do
      response = {
        udp: command_result('UDP', port: 54_321, status: udp_status),
        tcp: command_result('TCP', port: 54_322, status: tcp_status)
      }

      expect { described_class.new(helpers).forwarded_port(response) }
        .to raise_error(described_class::MappingError, /ports do not match \(54321 and 54322\)/)
    end

    it 'rejects malformed or missing mapped-port output for either protocol' do
      response = {
        udp: { stdout: 'unexpected output', stderr: '', status: udp_status },
        tcp: command_result('TCP', port: 54_321, status: tcp_status)
      }

      expect { described_class.new(helpers).forwarded_port(response) }
        .to raise_error(described_class::MappingError, /UDP NAT-PMP response/)
    end
  end
end
