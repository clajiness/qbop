require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'

SpecDatabase.reset!

RSpec.describe Source do # rubocop:disable Metrics/BlockLength
  before do
    SpecDatabase.reset!
  end

  it 'seeds one stat and one counter per source' do
    source = Source.create(name: 'proton')

    source.seed_tables
    source.seed_tables

    expect(DB[:stats].where(source_id: source.id).count).to eq(1)
    expect(DB[:counters].where(source_id: source.id).count).to eq(1)
  end

  it 'stores stat times as time values' do
    source = Source.create(name: 'proton')
    source.seed_tables

    source.set_last_checked
    source.set_updated_at

    expect(source.get_last_checked).to be_a(Time)
    expect(source.get_updated_at).to be_a(Time)
  end

  it 'preserves pending apply work when the target is reloaded and reseeded' do
    source = Source.create(name: 'opnsense').tap(&:seed_tables)
    source.set_pending_apply(23_456, 17)

    reloaded = Source[source.id]
    reloaded.seed_tables

    expect(reloaded.pending_apply_port).to eq(23_456)
    expect(reloaded.pending_apply_transition_id).to eq(17)
  end

  it 'clears only the target pending apply state' do
    source = Source.create(name: 'opnsense').tap(&:seed_tables)
    other = Source.create(name: 'qbit').tap(&:seed_tables)
    source.set_pending_apply(23_456, 17)
    source.change
    source.increment_attempt
    other_before = other.counter.values.dup

    source.clear_pending_apply

    expect(source.pending_apply_port).to be_nil
    expect(source.pending_apply_transition_id).to be_nil
    expect(source.change?).to eq(true)
    expect(source.attempt).to eq(1)
    expect(other.counter.refresh.values).to eq(other_before)
  end

  it 'returns stat snapshots as data objects keyed by source id' do
    source = Source.create(name: 'proton')
    source.seed_tables
    source.set_current_port(1234)

    snapshot = Stat.by_source_id[source.id]

    expect(snapshot).to be_a(Stat::Snapshot)
    expect(snapshot.current_port).to eq(1234)
    expect(snapshot[:current_port]).to eq(1234)
  end

  it 'returns stat snapshots keyed by source name' do
    source = Source.create(name: 'opnsense')
    source.seed_tables
    source.set_current_port(4321)

    snapshot = Stat.by_source_name['opnsense']

    expect(snapshot.source_name).to eq('opnsense')
    expect(snapshot.current_port).to eq(4321)
  end
end
