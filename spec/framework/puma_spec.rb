require 'bundler/setup'
require 'puma'
require 'puma/configuration'
require_relative '../../framework/events'

RSpec.describe 'Puma live-update runtime' do
  let(:configuration) { Puma::Configuration.new.tap(&:load).tap(&:clamp) }

  it 'keeps a single process and request capacity beyond the SSE subscriber limit' do
    expect(configuration.options[:workers]).to eq(0)
    expect(configuration.options[:max_threads]).to be > Framework::Events::MAX_SUBSCRIBERS
    expect(configuration.options[:force_shutdown_after]).to eq(5)
  end

  it 'closes subscribers safely when Puma invokes the stop hook from a signal trap' do
    stub_const('Framework::Events::INSTANCE', Framework::Events.new)
    subscriber = Framework::Events.subscribe
    events = configuration.events
    previous_handler = Signal.trap('USR1') { events.fire_after_stopped! }

    Process.kill('USR1', Process.pid)

    expect(subscriber.take(timeout: 2)).to be_nil
    expect(Framework::Events.subscribe).to be_nil
  ensure
    Signal.trap('USR1', previous_handler) if previous_handler
  end
end
