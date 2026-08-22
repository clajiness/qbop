module Framework
  # Keeps OmniAuth's useful failure type/class while dropping provider-controlled details.
  class OidcLogger
    FAILURE_PREFIX = 'Authentication failure!'.freeze

    def initialize(delegate)
      @delegate = delegate
    end

    %i[debug info warn error fatal unknown].each do |level|
      define_method(level) do |message = nil, &block|
        sanitized_block = -> { sanitize(block.call) } if block
        @delegate.public_send(level, sanitize(message), &sanitized_block)
      end
    end

    def method_missing(name, ...)
      @delegate.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @delegate.respond_to?(name, include_private) || super
    end

    private

    def sanitize(message)
      return message unless message.is_a?(String) && message.include?(FAILURE_PREFIX)

      prefix, details = message.split(FAILURE_PREFIX, 2)
      exception_class = details.match(/: ([A-Z][A-Za-z0-9_:]+)(?:,|\z)/)&.captures&.first
      ["#{prefix}#{FAILURE_PREFIX}", exception_class].compact.join(' ')
    end
  end
end
