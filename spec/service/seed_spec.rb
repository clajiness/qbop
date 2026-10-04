require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'
require_relative '../../service/seed'

RSpec.describe Service::Seed do # rubocop:disable Metrics/BlockLength
  around do |example|
    original_source = ENV['PORT_SOURCE']
    ENV.delete('PORT_SOURCE')
    example.run
  ensure
    original_source.nil? ? ENV.delete('PORT_SOURCE') : ENV['PORT_SOURCE'] = original_source
  end

  before do
    SpecDatabase.reset!
  end

  it 'creates the default sources with singleton stats and counters' do
    described_class.new

    expect(Source.order(:name).map(&:name)).to eq(%w[opnsense proton qbit])
    expect(Stat.count).to eq(3)
    expect(Counter.count).to eq(3)
  end

  it 'seeds Gluetun separately while preserving existing Proton records and history' do
    described_class.new
    proton = Source[name: 'proton']
    proton.set_current_port(12_345)
    transition = PortTransition.record_transition(
      previous_port: 0, new_port: 12_345, opnsense_skipped: false, qbit_skipped: false
    )
    ENV['PORT_SOURCE'] = 'gluetun'

    2.times { described_class.new }

    expect(Source[name: 'proton'].id).to eq(proton.id)
    expect(Source[name: 'proton'].get_current_port).to eq(12_345)
    expect(transition.refresh.source_name).to eq('proton')
    expect(Source[name: 'gluetun'].get_current_port).to eq(0)
    expect(Stat.count).to eq(4)
    expect(Counter.count).to eq(4)
  end

  it 'fails startup clearly on an invalid source selection' do
    ENV['PORT_SOURCE'] = 'invalid'

    expect { described_class.new }.to raise_error(Service::PortSource::ConfigurationError)
    expect(Source.count).to eq(0)
  end
end
