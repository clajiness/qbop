require 'bundler/setup'
Bundler.require(:default)
require_relative '../support/database_helper'
require_relative '../../service/synchronization_configuration'

RSpec.describe Service::SynchronizationConfiguration do # rubocop:disable Metrics/BlockLength
  let(:settings) { Service::Settings.new(environment: {}) }

  before { SpecDatabase.reset! }

  it 'uses configured values before startup without capturing that fallback' do
    expect(described_class.current(settings).to_h).to eq(
      port_source: 'proton', opnsense_skip: false, qbit_skip: false, loop_freq: 45
    )
    settings.set(:loop_freq, 60)

    expect(described_class.current(settings).loop_freq).to eq(60)
  end

  it 'captures only the four startup values and owns its immutable source string' do
    config = { port_source: +'gluetun', opnsense_skip: 'TRUE', qbit_skip: ' false ', loop_freq: 60,
               qbit_pass: 'private-credential' }
    snapshot = described_class.capture(config)
    config[:port_source].replace('proton')
    settings.set(:loop_freq, 120)

    expect(snapshot.to_h).to eq(port_source: 'gluetun', opnsense_skip: true, qbit_skip: false, loop_freq: 60)
    expect(snapshot).to be_frozen
    expect(snapshot.port_source).to be_frozen
    expect(snapshot.inspect).not_to include('private-credential')
    expect(described_class.current(settings)).to equal(snapshot)
  end

  it 'resolves status configuration without reading unrelated encrypted credentials' do
    Setting.create(name: 'qbit_pass', value: 'enc:v1:unreadable-credential')
    expect(Service::SettingsEncryption).not_to receive(:new)

    expect(described_class.resolve(settings).port_source).to eq('proton')
    expect(described_class.current(settings).loop_freq).to eq(45)
  end

  it 'compares source and skip flags while excluding loop frequency from pending-restart metadata' do
    snapshot = described_class.resolve(settings)

    expect(snapshot.source_or_skip_changed?(snapshot.with(loop_freq: 1))).to be(false)
    expect(snapshot.source_or_skip_changed?(snapshot.with(port_source: 'gluetun'))).to be(true)
    expect(snapshot.source_or_skip_changed?(snapshot.with(opnsense_skip: true))).to be(true)
    expect(snapshot.source_or_skip_changed?(snapshot.with(qbit_skip: true))).to be(true)
  end

  it 'clears captured state during reset so the next startup can use updated settings' do
    described_class.capture(described_class.resolve(settings).to_h)
    settings.set(:port_source, 'gluetun')
    expect(described_class.current(settings).port_source).to eq('proton')

    described_class.reset

    expect(described_class.current(settings).port_source).to eq('gluetun')
  end
end
