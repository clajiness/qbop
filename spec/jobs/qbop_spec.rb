require 'bundler/setup'
Bundler.require(:default)

require_relative '../../jobs/qbop'

QbopSourceData = Struct.new(:current_port, :attempt_count, :changed, keyword_init: true) do
  def increment_attempt = self.attempt_count += 1
  def attempt = attempt_count
  def change = self.changed = true
  def change? = changed
  def reset_change = self.changed = false
  def reset_attempt = self.attempt_count = 0
  def set_current_port(port) = self.current_port = port
  def get_current_port = current_port
  def set_updated_at = true
  def updated? = true
  def set_same_port = true
end

RSpec.describe Qbop do
  let(:logger) { instance_double(Logger, info: nil, error: nil) }
  let(:job) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@logger, logger)
      instance.instance_variable_set(:@config, { required_attempts: 2 })
    end
  end

  it 'rejects invalid forwarded ports' do
    source_data = QbopSourceData.new(current_port: 1111, attempt_count: 0, changed: false)

    expect(job.send(:sync_target_port, source_data, 1111, nil, 'qBit')).to eq(false)
    expect(source_data.attempt).to eq(0)
  end

  it 'waits for the configured number of mismatched attempts before changing' do
    source_data = QbopSourceData.new(current_port: 1111, attempt_count: 0, changed: false)

    expect(job.send(:sync_target_port, source_data, 1111, 2222, 'qBit')).to eq(false)
    expect(source_data.attempt).to eq(1)

    expect(job.send(:sync_target_port, source_data, 1111, 2222, 'qBit')).to eq(true)
    expect(source_data.change?).to eq(true)
  end

  it 'resets attempts and change state when ports match' do
    source_data = QbopSourceData.new(current_port: 2222, attempt_count: 2, changed: true)

    expect(job.send(:sync_target_port, source_data, 2222, 2222, 'qBit')).to eq(false)
    expect(source_data.attempt).to eq(0)
    expect(source_data.change?).to eq(false)
  end
end
