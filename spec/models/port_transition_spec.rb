require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'

SpecDatabase.reset!

RSpec.describe PortTransition do # rubocop:disable Metrics/BlockLength
  before do
    SpecDatabase.reset!
  end

  it 'records an initial assignment without a previous port' do
    transition = described_class.record_transition(
      previous_port: 0,
      new_port: 12_345,
      opnsense_skipped: false,
      qbit_skipped: true
    )

    expect(transition.previous_port).to be_nil
    expect(transition.new_port).to eq(12_345)
    expect(transition.source_name).to eq('proton')
    expect(transition.detected_at).to be_a(Time)
    expect(transition.sync_status('opnsense')).to eq('pending')
    expect(transition.sync_status('qbit')).to eq('skipped')
  end

  it 'isolates synchronization errors and recovery for identical ports from different sources' do
    attributes = { previous_port: 12_345, new_port: 23_456, opnsense_skipped: false, qbit_skipped: false }
    proton = described_class.record_transition(**attributes)
    gluetun = described_class.record_transition(**attributes, source_name: 'gluetun')

    described_class.mark_error('opnsense', 23_456)
    expect(described_class.sync_error?('opnsense', 23_456)).to eq(true)
    expect(described_class.sync_error?('opnsense', 23_456, source_name: 'gluetun')).to eq(false)
    expect(gluetun.refresh.sync_status('opnsense')).to eq('pending')

    described_class.mark_synced('opnsense', 23_456, source_name: 'gluetun')
    expect(gluetun.refresh.sync_status('opnsense')).to eq('synced')
    expect(proton.refresh.sync_status('opnsense')).to eq('error')
    described_class.mark_error('qbit', 23_456, source_name: 'gluetun')
    expect(proton.refresh.sync_status('qbit')).to eq('pending')
  end

  it 'marks the newest matching transition as synchronized' do
    older = described_class.record_transition(
      previous_port: 23_456,
      new_port: 12_345,
      opnsense_skipped: false,
      qbit_skipped: false
    )
    newer = described_class.record_transition(
      previous_port: 23_456,
      new_port: 12_345,
      opnsense_skipped: false,
      qbit_skipped: false
    )

    described_class.mark_synced('opnsense', 12_345)

    expect(older.refresh.opnsense_synced_at).to be_nil
    expect(newer.refresh.opnsense_synced_at).to be_a(Time)
    expect(newer.sync_status('opnsense')).to eq('synced')
  end

  it 'resolves only histories participating in the pending OPNsense apply' do # rubocop:disable Metrics/BlockLength
    attributes = { previous_port: 12_345, new_port: 23_456, opnsense_skipped: false, qbit_skipped: false }
    older = described_class.record_transition(**attributes)
    described_class.mark_error('opnsense', 23_456)
    origin = described_class.record_transition(**attributes)
    described_class.mark_error('opnsense', 23_456)
    gluetun = described_class.record_transition(**attributes, source_name: 'gluetun')
    described_class.mark_error('opnsense', 23_456, source_name: 'gluetun')
    unrelated = described_class.record_transition(**attributes, source_name: 'gluetun')
    described_class.mark_error('opnsense', 23_456, source_name: 'gluetun')
    different_port = described_class.record_transition(**attributes.merge(new_port: 34_567))
    skipped = described_class.record_transition(**attributes.merge(opnsense_skipped: true))
    synced = described_class.record_transition(**attributes)
    described_class.mark_synced('opnsense', 23_456, at: Time.at(10))
    unchanged = [older, unrelated, different_port, skipped, synced]
    before = unchanged.map { |record| record.refresh.values.dup }

    described_class.mark_opnsense_applied(
      23_456, transition_ids: [origin, gluetun, different_port, skipped, synced].map(&:id), at: Time.at(20)
    )

    expect(unchanged.map { |record| record.refresh.values }).to eq(before)
    [origin, gluetun].each do |record|
      expect(record.refresh.opnsense_synced_at).to eq(Time.at(20))
      expect(record.opnsense_error_at).to be_nil
      expect(record.sync_status('qbit')).to eq('pending')
    end
    expect(origin.source_name).to eq('proton')
    expect(gluetun.source_name).to eq('gluetun')
    expect(described_class.latest_for_port(23_456, 'proton').id).to eq(synced.id)
    expect(described_class.latest_for_port(23_456, 'gluetun').id).to eq(unrelated.id)
  end

  it 'uses only the last settled result for the requested port when recovering legacy apply errors' do
    attributes = { previous_port: 12_345, new_port: 23_456, opnsense_skipped: false, qbit_skipped: false }
    error = described_class.record_transition(**attributes)
    described_class.mark_error('opnsense', 23_456)
    described_class.record_transition(**attributes, source_name: 'gluetun')

    expect(described_class.pending_opnsense_error(23_456).id).to eq(error.id)
    expect(described_class.pending_opnsense_error(34_567)).to be_nil

    described_class.mark_synced('opnsense', 23_456, source_name: 'gluetun')
    expect(described_class.pending_opnsense_error(23_456)).to be_nil
  end

  { 'opnsense' => 20_000, 'qbit' => 20_001 }.each do |source, port|
    it "records the latest #{source} error and clears an earlier success" do
      transition = described_class.record_transition(
        previous_port: 12_345,
        new_port: port,
        opnsense_skipped: false,
        qbit_skipped: false
      )
      synced_column = "#{source}_synced_at"
      error_column = "#{source}_error_at"
      expect(transition.sync_status(source)).to eq('pending')

      described_class.mark_synced(source, port, at: Time.at(10))
      described_class.mark_error(source, port, at: Time.at(20))
      described_class.mark_error(source, port, at: Time.at(30))
      transition.refresh

      expect(transition.sync_status(source)).to eq('error')
      expect(described_class.sync_error?(source, port)).to eq(true)
      expect(transition.public_send(synced_column)).to be_nil
      expect(transition.public_send(error_column)).to eq(Time.at(30))
    end
  end

  it 'preserves skipped status for both integrations' do
    transition = described_class.record_transition(
      previous_port: 12_345,
      new_port: 23_456,
      opnsense_skipped: true,
      qbit_skipped: true
    )

    expect(transition.sync_status('opnsense')).to eq('skipped')
    expect(transition.sync_status('qbit')).to eq('skipped')
  end

  { 'opnsense' => 20_000, 'qbit' => 20_001 }.each do |source, port|
    it "replaces an #{source} error with one stable successful retry timestamp" do
      transition = described_class.record_transition(
        previous_port: 12_345,
        new_port: port,
        opnsense_skipped: false,
        qbit_skipped: false
      )
      synced_column = "#{source}_synced_at"
      error_column = "#{source}_error_at"
      described_class.mark_error(source, port, at: Time.at(10))

      described_class.mark_synced(source, port, at: Time.at(20))
      transition.refresh
      expect(transition.sync_status(source)).to eq('synced')
      expect(described_class.sync_error?(source, port)).to eq(false)
      expect(transition.public_send(synced_column)).to eq(Time.at(20))
      expect(transition.public_send(error_column)).to be_nil

      described_class.mark_synced(source, port, at: Time.at(30))
      expect(transition.refresh.public_send(synced_column)).to eq(Time.at(20))
    end
  end

  it 'retains only the newest 500 transitions' do
    501.times do |index|
      described_class.record_transition(
        previous_port: index + 10_000,
        new_port: index + 10_001,
        opnsense_skipped: false,
        qbit_skipped: false,
        detected_at: Time.at(index)
      )
    end

    expect(described_class.count).to eq(500)
    expect(described_class.order(:detected_at).first.new_port).to eq(10_002)
  end

  it 'paginates transitions newest first' do
    30.times do |index|
      described_class.record_transition(
        previous_port: index + 10_000,
        new_port: index + 10_001,
        opnsense_skipped: false,
        qbit_skipped: false,
        detected_at: Time.at(index)
      )
    end

    page = described_class.paginate(page: 2, per_page: 25)

    expect(page.total_records).to eq(30)
    expect(page.total_pages).to eq(2)
    expect(page.current_page).to eq(2)
    expect(page.from).to eq(26)
    expect(page.to).to eq(30)
    expect(page.records.map(&:new_port)).to eq([10_005, 10_004, 10_003, 10_002, 10_001])
  end
end
