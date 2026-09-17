require_relative '../../framework/event_stream'

RSpec.describe Framework::EventStream do # rubocop:disable Metrics/BlockLength
  let(:events) { Framework::Events.new }
  let(:subscriber) { events.subscribe }

  it 'sends an initial refresh and named invalidations with dispatchable empty data' do
    stream = described_class.new(subscriber, events: events)
    frames = []
    stream.each do |frame|
      frames << frame
      break if frames.length == 2

      events.publish(:status_changed)
    end

    expect(frames).to eq(["retry: 3000\nevent: refresh\ndata: \n\n", "event: status_changed\ndata: \n\n"])
    expect(subscriber.take(timeout: 0)).to be_nil
  end

  it 'refreshes on reconnect even when notifications were missed' do
    events.publish(:history_changed)
    2.times do
      frames = []
      described_class.new(events.subscribe, events: events, lifetime: 0).each { |frame| frames << frame }
      expect(frames).to eq(["retry: 3000\nevent: refresh\ndata: \n\n"])
    end
  end

  it 'sends idle comments without triggering a partial fetch' do
    frames = []
    described_class.new(subscriber, events: events, heartbeat: 0).each do |frame|
      frames << frame
      break if frames.length == 2
    end

    expect(frames.last).to eq(": heartbeat\n\n")
  end

  it 'releases the subscription when a socket write fails' do
    stream = described_class.new(subscriber, events: events)

    write = ->(_frame) { raise IOError, 'disconnected' }
    expect { stream.each(&write) }.to raise_error(IOError)
    expect(subscriber.take(timeout: 0)).to be_nil
  end

  it 'closes a body that was never enumerated' do
    stream = described_class.new(subscriber, events: events)
    2.times { stream.close }

    expect(subscriber.take(timeout: 0)).to be_nil
  end

  it 'ends when the broadcaster shuts down' do
    frames = []
    described_class.new(subscriber, events: events).each do |frame|
      frames << frame
      events.shutdown
    end

    expect(frames.length).to eq(1)
  end
end
