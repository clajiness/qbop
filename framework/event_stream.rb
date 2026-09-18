require_relative 'events'

module Framework
  # A Rack body. Puma owns socket writes; no socket work happens in the publisher.
  class EventStream
    HEARTBEAT_SECONDS = 15

    def initialize(subscriber, events: Events, heartbeat: HEARTBEAT_SECONDS)
      @subscriber = subscriber
      @events = events
      @heartbeat = heartbeat
    end

    def each
      # An empty data field is required for EventSource to dispatch a named event.
      yield "retry: 3000\nevent: refresh\ndata: \n\n"
      loop do
        events = @subscriber.take(timeout: @heartbeat)
        break unless events

        yield events.empty? ? ": heartbeat\n\n" : events.map { |event| "event: #{event}\ndata: \n\n" }.join
      end
    ensure
      close
    end

    def close
      @events.unsubscribe(@subscriber)
    end
  end
end
