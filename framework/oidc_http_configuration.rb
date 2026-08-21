module Framework
  # Applies fail-closed transport defaults to the OIDC dependency stack.
  class OidcHttpConfiguration
    OPEN_TIMEOUT = 5
    REQUEST_TIMEOUT = 10
    MAX_DISCOVERY_RESPONSE_BYTES = 65_536
    MAX_BACKCHANNEL_RESPONSE_BYTES = 1_048_576

    class ResponseTooLarge < StandardError; end

    def self.configure!
      SWD.http_config(&discovery_configuration)
      WebFinger.http_config(&discovery_configuration)
      OpenIDConnect.http_config(&request_configuration)
    end

    def self.discovery_configuration
      @discovery_configuration ||= lambda do |connection|
        configure_connection(connection, max_response_bytes: MAX_DISCOVERY_RESPONSE_BYTES)
        # Both discovery libraries install this middleware before invoking their
        # public configuration hook. Following redirects could otherwise permit
        # an HTTPS discovery request to be downgraded to plaintext before qbop
        # has an opportunity to validate the returned metadata.
        connection.builder.delete(Faraday::FollowRedirects::Middleware)
      end
    end
    private_class_method :discovery_configuration

    def self.request_configuration
      @request_configuration ||= lambda do |connection|
        configure_connection(connection, max_response_bytes: MAX_BACKCHANNEL_RESPONSE_BYTES)
      end
    end
    private_class_method :request_configuration

    def self.configure_connection(connection, max_response_bytes:)
      connection.options.open_timeout = OPEN_TIMEOUT
      connection.options.timeout = REQUEST_TIMEOUT
      connection.ssl.verify = true
      connection.use(response_size_middleware, max_bytes: max_response_bytes)
    end
    private_class_method :configure_connection

    def self.response_size_middleware # rubocop:disable Metrics/MethodLength
      @response_size_middleware ||= Class.new(Faraday::Middleware) do
        def initialize(app, max_bytes:)
          super(app)
          @max_bytes = max_bytes
        end

        def on_complete(environment)
          body = environment.body
          return unless body.respond_to?(:bytesize) && body.bytesize > @max_bytes

          raise Framework::OidcHttpConfiguration::ResponseTooLarge, 'OIDC response exceeded the size limit'
        end
      end
    end
    private_class_method :response_size_middleware
  end
end
