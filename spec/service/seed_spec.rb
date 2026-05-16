require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'
require_relative '../../service/seed'

RSpec.describe Service::Seed do
  before do
    SpecDatabase.reset!
  end

  it 'creates the default sources with singleton stats and counters' do
    described_class.new

    expect(Source.order(:name).map(&:name)).to eq(%w[opnsense proton qbit])
    expect(Stat.count).to eq(3)
    expect(Counter.count).to eq(3)
  end
end
