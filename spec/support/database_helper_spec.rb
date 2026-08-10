require 'bundler/setup'
Bundler.require(:default)

require_relative 'database_helper'

RSpec.describe SpecDatabase do
  it 'does not reuse associations from before a reset' do
    described_class.reset!
    old_source = Source.create(name: 'qbit')
    old_source.seed_tables
    old_source.set_current_port(23_456)

    described_class.reset!
    new_source = Source.create(name: 'proton')
    new_source.seed_tables

    expect(new_source.get_current_port).to eq(0)
  end
end
