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

      expect(result).to eq(stdout: 'udp outputtcp output', stderr: '', status: tcp_status)
    end

    it 'does not run TCP natpmpc when UDP fails' do
      failed_status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3)
        .with('timeout', '40', 'natpmpc', '-a', '1', '0', 'udp', '60', '-g', '10.2.0.1')
        .and_return(['', 'udp failed', failed_status])

      result = described_class.new(helpers).natpmpc('10.2.0.1')

      expect(Open3).to have_received(:capture3).once
      expect(result).to eq(stdout: '', stderr: 'udp failed', status: failed_status)
    end
  end

  describe '#parse_response' do
    it 'returns the mapped public port' do
      response = 'Mapped public port 54321 protocol TCP'

      expect(described_class.new(helpers).parse_response(response)).to eq(54_321)
    end
  end
end
