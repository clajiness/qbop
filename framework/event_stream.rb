require_relative 'events'

module Framework
  # A Rack body. Puma owns socket writes; no socket work happens in the publisher.
  class EventStream
    HEARTBEAT_SECONDS = 15
    LIFETIME_SECONDS = 300

    def initialize(subscriber, events: Events, heartbeat: HEARTBEAT_SECONDS, lifetime: LIFETIME_SECONDS)
      @subscriber = subscriber
      @events = events
      @heartbeat = heartbeat
      @lifetime = lifetime
    end

    def each
      deadline = monotonic_time + @lifetime
      # An empty data field is required for EventSource to dispatch a named event.
      yield "retry: 3000\nevent: refresh\ndata: \n\n"
      while (remaining = deadline - monotonic_time).positive?
        events = @subscriber.take(timeout: [@heartbeat, remaining].min)
        break unless events

        yield events.empty? ? ": heartbeat\n\n" : events.map { |event| "event: #{event}\ndata: \n\n" }.join
      end
    ensure
      close
    end

    def close
      @events.unsubscribe(@subscriber)
    end

    private

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
