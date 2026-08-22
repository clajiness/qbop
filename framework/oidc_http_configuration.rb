module Framework
  # Applies fail-closed transport defaults to the OIDC dependency stack.
  class OidcHttpConfiguration
    OPEN_TIMEOUT = 5
    REQUEST_TIMEOUT = 10

    def self.configure!
      SWD.http_config(&discovery_configuration)
      OpenIDConnect.http_config(&request_configuration)
    end

    def self.discovery_configuration
      @discovery_configuration ||= lambda do |connection|
        configure_connection(connection)
        # SWD installs this middleware before invoking its configuration hook.
        # Following redirects could otherwise downgrade discovery to plaintext
        # before qbop can validate the returned metadata.
        connection.builder.delete(Faraday::FollowRedirects::Middleware)
      end
    end
    private_class_method :discovery_configuration

    def self.request_configuration
      @request_configuration ||= lambda do |connection|
        configure_connection(connection)
      end
    end
    private_class_method :request_configuration

    def self.configure_connection(connection)
      connection.options.open_timeout = OPEN_TIMEOUT
      connection.options.timeout = REQUEST_TIMEOUT
      connection.ssl.verify = true
    end
    private_class_method :configure_connection
  end
end
