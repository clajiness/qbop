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
    2.times do
      events.publish(:history_changed)
      subscriber = events.subscribe
      frames = []
      described_class.new(subscriber, events: events).each do |frame|
        frames << frame
        events.unsubscribe(subscriber)
      end
      expect(frames).to eq(["retry: 3000\nevent: refresh\ndata: \n\n"])
    end
  end

  it 'keeps sending 15-second heartbeats beyond five minutes until the subscriber closes' do
    elapsed = 0
    allow(subscriber).to receive(:take).with(timeout: 15) do
      elapsed += 15
      [] if elapsed < 330
    end
    frames = []

    described_class.new(subscriber, events: events).each { |frame| frames << frame }

    expect(elapsed).to eq(330)
    expect(frames.drop(1)).to eq(Array.new(21, ": heartbeat\n\n"))
    expect(subscriber).to have_received(:take).with(timeout: 15).exactly(22).times
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
    events.publish(:status_changed)

    write = ->(frame) { raise IOError, 'disconnected' if frame.include?('status_changed') }
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

  it 'wakes and cleans up a waiting stream when the server shuts down' do
    waiting = Queue.new
    allow(subscriber).to receive(:take).and_wrap_original do |original, **options|
      waiting << true
      original.call(**options)
    end
    stream = described_class.new(subscriber, events: events)
    reader = Thread.new { stream.each { |_frame| nil } }
    expect(waiting.pop(timeout: 1)).to be(true)

    events.shutdown

    expect(reader.join(1)).to eq(reader)
    expect(subscriber.take(timeout: 0)).to be_nil
  ensure
    stream&.close
    reader&.kill
  end
end
