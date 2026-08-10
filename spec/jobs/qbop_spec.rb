require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'
require_relative '../../service/helpers'
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

RSpec.describe Qbop do # rubocop:disable Metrics/BlockLength
  let(:logger) { instance_double(Logger, info: nil, error: nil) }
  let(:job) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@logger, logger)
      instance.instance_variable_set(:@config, { required_attempts: 2 })
    end
  end

  before do
    SpecDatabase.reset!
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

  it 'records a port transition with integration skip state' do
    helpers = instance_double(Service::Helpers)
    allow(helpers).to receive(:true?) { |value| value == 'true' }
    job.instance_variable_set(:@helpers, helpers)
    job.instance_variable_set(:@config, { opnsense_skip: 'false', qbit_skip: 'true' })

    job.send(:record_port_transition, 12_345, 23_456)

    transition = PortTransition.first
    expect(transition.previous_port).to eq(12_345)
    expect(transition.new_port).to eq(23_456)
    expect(transition.opnsense_skipped).to eq(false)
    expect(transition.qbit_skipped).to eq(true)
  end

  it 'records only new Proton port assignments' do
    source = Source.create(name: 'proton')
    source.seed_tables
    helpers = Service::Helpers.new
    proton = double(
      natpmpc: { stdout: 'Mapped public port 23456 protocol TCP', stderr: '' },
      parse_response: 23_456
    )
    job.instance_variable_set(:@helpers, helpers)
    job.instance_variable_set(:@config, { proton_gateway: '10.2.0.1', opnsense_skip: 'false', qbit_skip: 'false' })
    job.instance_variable_set(:@proton, proton)
    job.instance_variable_set(:@proton_data, source)

    2.times { job.send(:handle_proton) }

    expect(PortTransition.count).to eq(1)
    expect(PortTransition.first.previous_port).to be_nil
    expect(PortTransition.first.new_port).to eq(23_456)
  end

  it 'marks matching targets as synchronized' do
    source = Source.create(name: 'qbit')
    source.seed_tables
    source.set_current_port(23_456)
    transition = PortTransition.record_transition(
      previous_port: 12_345,
      new_port: 23_456,
      opnsense_skipped: false,
      qbit_skipped: false
    )

    result = job.send(:sync_target_port, source, 23_456, 23_456, 'qBit', 'qbit')

    expect(result).to eq(false)
    expect(transition.refresh.qbit_synced_at).to be_a(Time)
  end
end
