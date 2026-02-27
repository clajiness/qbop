module Framework
  # tracks the uptime of the application
  class Uptime
    # the time when the application started
    STARTED_AT = Time.now

    # returns the time when the application started
    def self.started_at
      STARTED_AT
    end

    # returns the uptime in seconds
    def self.uptime_seconds
      Time.now - STARTED_AT
    end
  end
end
