require_relative '../../framework/events'

RSpec.describe Framework::Events do # rubocop:disable Metrics/BlockLength
  subject(:events) { described_class.new }

  it 'delivers semantic events to multiple independent subscribers' do
    first = events.subscribe
    second = events.subscribe
    events.publish(:status_changed)
    events.publish(:history_changed)

    expect(first.take(timeout: 0)).to eq(%i[status_changed history_changed])
    expect(second.take(timeout: 0)).to eq(%i[status_changed history_changed])
    expect(first.take(timeout: 0)).to eq([])
  end

  it 'unsubscribes idempotently and leaves other subscribers connected' do
    first = events.subscribe
    second = events.subscribe
    2.times { events.unsubscribe(first) }
    events.publish(:logs_changed)

    expect(first.take(timeout: 0)).to be_nil
    expect(second.take(timeout: 0)).to eq([:logs_changed])
  end

  it 'bounds pending notifications without a slow subscriber blocking publishers' do
    stalled = events.subscribe
    active = events.subscribe
    1000.times do
      described_class::NAMES.each { |name| events.publish(name) }
      expect(active.take(timeout: 0)).to eq(described_class::NAMES)
    end

    expect(stalled.take(timeout: 0)).to eq(described_class::NAMES)
  end

  it 'limits subscribers and reuses a disconnected slot' do
    subscribers = Array.new(described_class::MAX_SUBSCRIBERS) { events.subscribe }
    expect(events.subscribe).to be_nil

    events.unsubscribe(subscribers.first)
    expect(events.subscribe).to be_a(described_class::Subscription)
  end

  it 'handles concurrent publishers and subscribers' do
    subscriber = events.subscribe
    threads = described_class::NAMES.map do |name|
      Thread.new do
        100.times do
          events.publish(name)
          temporary = events.subscribe
          events.unsubscribe(temporary) if temporary
        end
      end
    end
    threads.each(&:value)

    expect(subscriber.take(timeout: 0)).to match_array(described_class::NAMES)
  end

  it 'wakes blocked readers and rejects new subscriptions at shutdown' do
    subscriber = events.subscribe
    reader = Thread.new { subscriber.take(timeout: 60) }
    events.shutdown

    expect(reader.join(1)).to eq(reader)
    expect(reader.value).to be_nil
    expect(events.subscribe).to be_nil
    expect { events.publish(:status_changed) }.not_to raise_error
  ensure
    reader&.kill
  end

  it 'rejects arbitrary event names or payloads' do
    expect { events.publish("status_changed\ndata: secret") }.to raise_error(ArgumentError)
  end
end
