module Framework
  # Process-local invalidations only: consumers always read current state from Sinatra.
  class Events
    NAMES = %i[status_changed history_changed logs_changed].freeze
    MAX_SUBSCRIBERS = 8

    # Coalesce repeated names, so even a stalled browser retains at most three events.
    class Subscription
      def initialize
        @mutex = Mutex.new
        @ready = ConditionVariable.new
        @pending = []
        @closed = false
      end

      def push(event)
        @mutex.synchronize do
          return if @closed

          @pending |= [event]
          @ready.signal
        end
      end

      def take(timeout:)
        @mutex.synchronize do
          @ready.wait(@mutex, timeout) if @pending.empty? && !@closed
          return if @closed

          @pending.shift(@pending.length)
        end
      end

      def close
        @mutex.synchronize do
          @closed = true
          @pending.clear
          @ready.broadcast
        end
      end
    end

    def initialize
      @mutex = Mutex.new
      @subscribers = []
      @closed = false
    end

    def subscribe
      @mutex.synchronize do
        return if @closed || @subscribers.length >= MAX_SUBSCRIBERS

        Subscription.new.tap { |subscriber| @subscribers << subscriber }
      end
    end

    def publish(event)
      raise ArgumentError, 'unknown UI event' unless NAMES.include?(event)

      @mutex.synchronize { @subscribers.each { |subscriber| subscriber.push(event) } }
    end

    def unsubscribe(subscriber)
      @mutex.synchronize do
        @subscribers.delete(subscriber)
        subscriber.close
      end
    end

    def shutdown
      @mutex.synchronize do
        @closed = true
        @subscribers.each(&:close)
        @subscribers.clear
      end
    end

    INSTANCE = new

    def self.subscribe = INSTANCE.subscribe
    def self.publish(event) = INSTANCE.publish(event)
    def self.unsubscribe(subscriber) = INSTANCE.unsubscribe(subscriber)
    def self.shutdown = INSTANCE.shutdown
  end
end
