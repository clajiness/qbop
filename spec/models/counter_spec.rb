require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'

SpecDatabase.reset!

RSpec.describe Counter do
  before do
    SpecDatabase.reset!
  end

  it 'returns counter snapshots keyed by source name' do
    source = Source.create(name: 'proton')
    counter = Counter.create(source_id: source.id, attempt: 2, change: true)

    snapshot = described_class.by_source_name['proton']

    expect(snapshot).to eq(counter.to_snapshot)
    expect(snapshot.change?).to eq(true)
    expect(snapshot[:attempt]).to eq(2)
  end
end
