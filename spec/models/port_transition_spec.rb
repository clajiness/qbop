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
    expect(transition.detected_at).to be_a(Time)
    expect(transition.sync_status('opnsense')).to eq('pending')
    expect(transition.sync_status('qbit')).to eq('skipped')
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
