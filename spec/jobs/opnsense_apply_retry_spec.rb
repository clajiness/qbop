require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'
require_relative '../../service/helpers'
require_relative '../../service/opnsense'
require_relative '../../service/qbit'
require_relative '../../jobs/qbop'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'OPNsense pending apply persistence' do
  let(:logger) { instance_double(Logger, info: nil, error: nil) }
  let(:opnsense) { instance_double(Service::Opnsense, get_alias_uuid: 'alias-uuid') }

  before do
    SpecDatabase.reset!
    %w[proton gluetun opnsense qbit].each do |name|
      Source.create(name: name).tap(&:seed_tables).set_current_port(12_345)
    end
    @alias_port = 12_345
    @apply_statuses = [500, 500, 200]
    @applied_ports = []
    allow(opnsense).to receive(:get_alias_value) { @alias_port }
    allow(opnsense).to receive(:set_alias_value) { |port, _uuid| @alias_port = port }
    allow(opnsense).to receive(:apply_changes) do
      @applied_ports << @alias_port
      double(status: @apply_statuses.shift || 200)
    end
    allow(Service::Opnsense).to receive(:new).and_return(opnsense)
    allow(Service::Qbit).to receive(:new).and_return(instance_double(Service::Qbit))
  end

  def new_job(source_name, port = 23_456, required_attempts: 1) # rubocop:disable Metrics/AbcSize
    helpers = Service::Helpers.new
    config = helpers.env_variables.merge(port_source: source_name, opnsense_skip: 'false', qbit_skip: 'true',
                                         required_attempts: required_attempts)
    allow(helpers).to receive_messages(env_variables: config, logger_instance: logger)
    allow(Service::Helpers).to receive(:new).and_return(helpers)
    source_class = source_name == 'proton' ? Service::Proton : Service::Gluetun
    source = instance_double(source_class, name: source_name, current_port: port)
    allow(Service::PortSource).to receive(:build).with(helpers, config).and_return(source)

    Qbop.allocate.tap { |job| job.send(:initialize_dependencies) }
  end

  def check(job)
    job.send(:synchronize_port, job.send(:handle_port_forwarding))
  end

  def target
    Source[name: 'opnsense']
  end

  [%w[proton proton], %w[proton gluetun], %w[gluetun proton]].each do |original, selected|
    it "retries #{original} -> #{selected} after restart, with no false success or continued retries" do
      check(new_job(original))
      original_history = PortTransition.latest_for_port(23_456, original)
      expect(original_history.sync_status('opnsense')).to eq('error')
      expect(target.pending_apply_port).to eq(23_456)
      expect(target.pending_apply_transition_id).to eq(original_history.id)
      expect(target.get_current_port).to eq(12_345)
      expect(target.get_updated_at).to be_nil

      restarted = new_job(selected)
      port = restarted.send(:handle_port_forwarding)
      selected_history = PortTransition.latest_for_port(port, selected)
      expect(selected_history.sync_status('opnsense')).to eq(original == selected ? 'error' : 'pending')

      restarted.send(:handle_opnsense, port)
      expect(selected_history.refresh.sync_status('opnsense')).to eq('error')
      expect(target.get_current_port).to eq(12_345)
      expect(target.get_updated_at).to be_nil
      expect(target.pending_apply_transition_id).to eq(original_history.id)

      check(restarted)
      [original_history, selected_history].each do |history|
        expect(history.refresh.sync_status('opnsense')).to eq('synced')
        expect(history.opnsense_error_at).to be_nil
        expect(history.sync_status('qbit')).to eq('skipped')
      end
      expect(original_history.source_name).to eq(original)
      expect(selected_history.source_name).to eq(selected)
      expect(target.get_current_port).to eq(23_456)
      expect(target.get_updated_at).to be_a(Time)
      expect(target.pending_apply_port).to be_nil
      expect(target.pending_apply_transition_id).to be_nil
      expect(target.change?).to eq(false)
      expect(target.attempt).to eq(0)

      completed_at = selected_history.opnsense_synced_at
      check(restarted)
      expect(selected_history.refresh.opnsense_synced_at).to eq(completed_at)
      expect(opnsense).to have_received(:set_alias_value).with(23_456, 'alias-uuid').once
      expect(opnsense).to have_received(:apply_changes).exactly(3).times
    end
  end

  it 'resolves every participating history when switching sources more than once before success' do
    check(new_job('proton'))
    check(new_job('gluetun'))
    proton = new_job('proton')
    check(proton)

    expect(PortTransition.order(:id).map(&:source_name)).to eq(%w[proton gluetun])
    expect(PortTransition.all.map { |history| history.sync_status('opnsense') }).to eq(%w[synced synced])
    expect(target.pending_apply_port).to be_nil
    check(proton)
    expect(opnsense).to have_received(:apply_changes).exactly(3).times
  end

  it 'updates a different desired port through the normal mismatch flow instead of applying the obsolete port' do
    check(new_job('proton'))
    original_history = PortTransition.first
    @apply_statuses = [200]
    gluetun = new_job('gluetun', 34_567)
    check(gluetun)

    expect(@applied_ports).to eq([23_456, 34_567])
    expect(opnsense).to have_received(:set_alias_value).with(34_567, 'alias-uuid').once
    expect(original_history.refresh.sync_status('opnsense')).to eq('error')
    expect(PortTransition.latest_for_port(34_567, 'gluetun').sync_status('opnsense')).to eq('synced')
    expect(target.get_current_port).to eq(34_567)
    expect(target.pending_apply_port).to be_nil
    check(gluetun)
    expect(opnsense).to have_received(:apply_changes).twice
  end

  it 'retains existing confirmation thresholds before writing an alias or creating pending apply state' do
    job = new_job('proton', required_attempts: 2)

    check(job)

    expect(target.attempt).to eq(1)
    expect(target.change?).to eq(false)
    expect(target.pending_apply_port).to be_nil
    expect(opnsense).not_to have_received(:set_alias_value)
    expect(opnsense).not_to have_received(:apply_changes)
    check(job)
    expect(target.pending_apply_port).to eq(23_456)
    expect(opnsense).to have_received(:set_alias_value).once
  end

  it 'discards obsolete pending work when the alias already matches a different desired port' do
    check(new_job('proton'))
    @alias_port = 34_567

    check(new_job('gluetun', 34_567))

    expect(target.pending_apply_port).to be_nil
    expect(target.pending_apply_transition_id).to be_nil
    expect(PortTransition.latest_for_port(23_456, 'proton').sync_status('opnsense')).to eq('error')
    expect(PortTransition.latest_for_port(34_567, 'gluetun').sync_status('opnsense')).to eq('synced')
    expect(opnsense).to have_received(:apply_changes).once

    @alias_port = 23_456
    check(new_job('proton'))
    expect(opnsense).to have_received(:apply_changes).once
  end

  it 'retains pending apply state after a transport exception and recovers through the other source' do
    allow(opnsense).to receive(:apply_changes).and_raise(Faraday::TimeoutError)

    check(new_job('gluetun'))

    expect(target.pending_apply_port).to eq(23_456)
    expect(PortTransition.first.sync_status('opnsense')).to eq('error')
    allow(opnsense).to receive(:apply_changes).and_return(double(status: 200))
    check(new_job('proton'))
    expect(target.pending_apply_port).to be_nil
    expect(PortTransition.all.map { |history| history.sync_status('opnsense') }).to eq(%w[synced synced])
  end

  it 'retries even if the originating history has been pruned' do
    check(new_job('proton'))
    origin_id = target.pending_apply_transition_id
    PortTransition.where(id: origin_id).delete
    @apply_statuses = [200]

    check(new_job('gluetun'))

    expect(PortTransition.first.source_name).to eq('gluetun')
    expect(PortTransition.first.sync_status('opnsense')).to eq('synced')
    expect(target.pending_apply_port).to be_nil
    expect(opnsense).to have_received(:set_alias_value).once
    expect(opnsense).to have_received(:apply_changes).twice
  end

  it 'persists pending apply work when there was no source transition and binds later history on retry' do
    Source[name: 'proton'].set_current_port(23_456)
    check(new_job('proton'))
    expect(PortTransition.count).to eq(0)
    expect(target.pending_apply_port).to eq(23_456)
    expect(target.pending_apply_transition_id).to be_nil
    @apply_statuses = [200]

    check(new_job('gluetun'))

    expect(PortTransition.first.sync_status('opnsense')).to eq('synced')
    expect(target.pending_apply_port).to be_nil
  end

  it 'recovers a matching legacy error after switching sources without treating unrelated ports as pending' do
    check(new_job('proton'))
    target.clear_pending_apply # State available before migration 009.
    expect(target.change?).to eq(true)
    @apply_statuses = [200]

    check(new_job('gluetun'))

    expect(PortTransition.all.map { |history| history.sync_status('opnsense') }).to eq(%w[synced synced])
    expect(target.pending_apply_port).to be_nil
    expect(opnsense).to have_received(:set_alias_value).once
    expect(opnsense).to have_received(:apply_changes).twice
  end

  it 'does not infer a retry from unrelated or already completed source history' do
    check(new_job('proton'))
    target.clear_pending_apply
    @alias_port = 34_567

    check(new_job('gluetun', 34_567))

    expect(PortTransition.latest_for_port(23_456, 'proton').sync_status('opnsense')).to eq('error')
    expect(PortTransition.latest_for_port(34_567, 'gluetun').sync_status('opnsense')).to eq('synced')
    expect(opnsense).to have_received(:apply_changes).once
    @alias_port = 23_456
    check(new_job('gluetun'))
    expect(opnsense).to have_received(:apply_changes).once
  end

  it 'does not create pending apply work after a rejected alias write' do
    allow(opnsense).to receive(:set_alias_value).and_raise(Service::Opnsense::AliasUpdateError)

    check(new_job('proton'))

    expect(target.pending_apply_port).to be_nil
    expect(PortTransition.first.sync_status('opnsense')).to eq('error')
    check(new_job('gluetun', 12_345))
    expect(opnsense).not_to have_received(:apply_changes)
  end
end
# rubocop:enable Metrics/BlockLength
