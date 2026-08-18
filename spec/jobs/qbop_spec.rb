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

  def record_transition(port = 23_456)
    PortTransition.record_transition(
      previous_port: 12_345,
      new_port: port,
      opnsense_skipped: false,
      qbit_skipped: false
    )
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

  it 'uses an existing Proton port as the first transition baseline after an upgrade' do
    source = Source.create(name: 'proton')
    source.seed_tables
    source.set_current_port(12_345)
    helpers = Service::Helpers.new
    proton = double(natpmpc: { stdout: 'Mapped public port', stderr: '' })
    allow(proton).to receive(:parse_response).and_return(12_345, 23_456, 23_456)
    job.instance_variable_set(:@helpers, helpers)
    job.instance_variable_set(:@config, { proton_gateway: '10.2.0.1', opnsense_skip: 'false', qbit_skip: 'false' })
    job.instance_variable_set(:@proton, proton)
    job.instance_variable_set(:@proton_data, source)

    job.send(:handle_proton)

    expect(PortTransition.count).to eq(0)
    expect(source.get_current_port).to eq(12_345)

    job.send(:handle_proton)

    expect(PortTransition.count).to eq(1)
    expect(PortTransition.first.previous_port).to eq(12_345)
    expect(PortTransition.first.new_port).to eq(23_456)
    expect(source.get_current_port).to eq(23_456)

    job.send(:handle_proton)

    expect(PortTransition.count).to eq(1)
    expect(source.get_current_port).to eq(23_456)
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

  it 'marks qBit transitions as synchronized after a successful update' do
    source = Source.create(name: 'qbit')
    source.seed_tables
    transition = PortTransition.record_transition(
      previous_port: 12_345,
      new_port: 23_456,
      opnsense_skipped: false,
      qbit_skipped: false
    )
    qbit = double(qbt_app_set_preferences: double(status: 200))
    job.instance_variable_set(:@qbit, qbit)
    job.instance_variable_set(:@qbit_data, source)

    job.send(:update_qbit_port, 23_456)

    expect(source.get_current_port).to eq(23_456)
    expect(transition.refresh.qbit_synced_at).to be_a(Time)
    expect(transition.sync_status('qbit')).to eq('synced')
  end

  it 'marks OPNsense transitions as synchronized after changes are applied' do
    source = Source.create(name: 'opnsense')
    source.seed_tables
    transition = PortTransition.record_transition(
      previous_port: 12_345,
      new_port: 23_456,
      opnsense_skipped: false,
      qbit_skipped: false
    )
    opnsense = double(
      set_alias_value: double(status: 200),
      apply_changes: double(status: 200)
    )
    job.instance_variable_set(:@opnsense, opnsense)
    job.instance_variable_set(:@opnsense_data, source)

    job.send(:update_opnsense_alias, 23_456, 'alias-uuid')

    expect(source.get_current_port).to eq(23_456)
    expect(transition.refresh.opnsense_synced_at).to be_a(Time)
    expect(transition.sync_status('opnsense')).to eq('synced')
  end

  it 'records a qBit write failure without affecting a successful OPNsense result' do
    transition = record_transition
    qbit_source = Source.create(name: 'qbit')
    qbit_source.seed_tables
    opnsense_source = Source.create(name: 'opnsense')
    opnsense_source.seed_tables
    job.instance_variable_set(:@qbit, double(qbt_app_set_preferences: double(status: 500)))
    job.instance_variable_set(:@qbit_data, qbit_source)
    job.instance_variable_set(
      :@opnsense,
      double(set_alias_value: double(status: 200), apply_changes: double(status: 200))
    )
    job.instance_variable_set(:@opnsense_data, opnsense_source)

    job.send(:update_qbit_port, 23_456)
    job.send(:update_opnsense_alias, 23_456, 'alias-uuid')

    expect(transition.refresh.sync_status('qbit')).to eq('error')
    expect(transition.sync_status('opnsense')).to eq('synced')
    expect(transition.qbit_synced_at).to be_nil
    expect(transition.opnsense_error_at).to be_nil
  end

  { 'alias update' => [500, 200], 'apply' => [200, 500] }.each do |stage, statuses|
    it "records an OPNsense error when the #{stage} response is unsuccessful" do
      transition = record_transition
      opnsense_source = Source.create(name: 'opnsense')
      opnsense_source.seed_tables
      opnsense = double(
        set_alias_value: double(status: statuses.first),
        apply_changes: double(status: statuses.last)
      )
      job.instance_variable_set(:@opnsense, opnsense)
      job.instance_variable_set(:@opnsense_data, opnsense_source)

      job.send(:update_opnsense_alias, 23_456, 'alias-uuid')

      expect(transition.refresh.sync_status('opnsense')).to eq('error')
      expect(transition.opnsense_synced_at).to be_nil
      expect(transition.qbit_error_at).to be_nil
    end
  end

  it 'records exceptions raised by synchronization writes and reraises them for existing logging' do
    transition = record_transition
    qbit = double
    allow(qbit).to receive(:qbt_app_set_preferences).and_raise(Faraday::Error)
    job.instance_variable_set(:@qbit, qbit)

    expect { job.send(:update_qbit_port, 23_456) }.to raise_error(Faraday::Error)

    opnsense = double
    allow(opnsense).to receive(:set_alias_value).and_raise(Faraday::Error)
    job.instance_variable_set(:@opnsense, opnsense)

    expect { job.send(:update_opnsense_alias, 23_456, 'alias-uuid') }.to raise_error(Faraday::Error)
    expect(transition.refresh.sync_status('qbit')).to eq('error')
    expect(transition.sync_status('opnsense')).to eq('error')
  end

  it 'does not record qBit read failures as synchronization errors' do
    transition = record_transition
    helpers = instance_double(Service::Helpers, true?: false)
    qbit_source = Source.create(name: 'qbit')
    qbit_source.seed_tables
    qbit = double
    allow(qbit).to receive(:qbt_app_preferences).and_raise(Faraday::Error)
    job.instance_variable_set(:@helpers, helpers)
    job.instance_variable_set(:@config, { qbit_skip: false, required_attempts: 2 })
    job.instance_variable_set(:@qbit, qbit)
    job.instance_variable_set(:@qbit_data, qbit_source)

    job.send(:handle_qbit, 23_456)

    expect(transition.refresh.sync_status('qbit')).to eq('pending')
  end

  it 'does not record OPNsense read failures as synchronization errors' do
    transition = record_transition
    helpers = instance_double(Service::Helpers, true?: false)
    opnsense_source = Source.create(name: 'opnsense')
    opnsense_source.seed_tables
    opnsense = double
    allow(opnsense).to receive(:get_alias_uuid).and_raise(Faraday::Error)
    job.instance_variable_set(:@helpers, helpers)
    job.instance_variable_set(:@config, { opnsense_skip: false, required_attempts: 2 })
    job.instance_variable_set(:@opnsense, opnsense)
    job.instance_variable_set(:@opnsense_data, opnsense_source)

    job.send(:handle_opnsense, 23_456)

    expect(transition.refresh.sync_status('opnsense')).to eq('pending')
  end
end
