require 'bundler/setup'
Bundler.require(:default)
require_relative '../support/database_helper'

RSpec.describe 'Committed model notifications' do # rubocop:disable Metrics/BlockLength
  before do
    SpecDatabase.reset!
    @source = Source.create(name: 'proton')
    @source.seed_tables
    @subscriber = Framework::Events.subscribe
  end

  after { Framework::Events.unsubscribe(@subscriber) }

  it 'publishes source timestamps and ports only after the transaction commits' do
    DB.transaction do
      @source.set_current_port(23_456)
      @source.set_last_checked
      @source.set_updated_at
      expect(@subscriber.take(timeout: 0)).to eq([])
    end

    expect(@subscriber.take(timeout: 0)).to eq([:status_changed])
  end

  it 'does not publish rolled-back stats or transitions' do
    DB.transaction(rollback: :always) do
      @source.set_current_port(23_456)
      PortTransition.record_transition(
        previous_port: 12_345, new_port: 23_456, opnsense_skipped: false, qbit_skipped: false
      )
    end

    expect(@subscriber.take(timeout: 0)).to eq([])
    expect(PortTransition.count).to eq(0)
  end

  it 'notifies history only after the new transition and retention changes commit' do
    DB.transaction do
      PortTransition.record_transition(
        previous_port: 12_345, new_port: 23_456, opnsense_skipped: false, qbit_skipped: false
      )
      expect(@subscriber.take(timeout: 0)).to eq([])
    end

    expect(@subscriber.take(timeout: 0)).to contain_exactly(:history_changed, :status_changed)
  end

  it 'does not republish an already completed synchronization' do
    PortTransition.record_transition(
      previous_port: 12_345, new_port: 23_456, opnsense_skipped: false, qbit_skipped: false
    )
    PortTransition.mark_synced('qbit', 23_456)
    @subscriber.take(timeout: 0)
    PortTransition.mark_synced('qbit', 23_456)

    expect(@subscriber.take(timeout: 0)).to eq([])
  end
end
