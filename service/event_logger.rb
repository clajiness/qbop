require 'logger'
require_relative '../framework/events'

module Service
  # Notify only after a file log entry has been written, including rotating logs.
  class EventLogger < Logger
    def add(severity, message = nil, progname = nil, &)
      return super if severity && severity < level

      super.tap { Framework::Events.publish(:logs_changed) }
    end
  end
end
