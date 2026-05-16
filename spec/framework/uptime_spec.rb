require 'bundler/setup'
Bundler.require(:default)

require_relative '../../framework/uptime'

RSpec.describe Framework::Uptime do
  it 'returns the application start time' do
    expect(described_class.started_at).to be_a(Time)
  end

  it 'returns uptime seconds' do
    expect(described_class.uptime_seconds).to be >= 0
  end
end
