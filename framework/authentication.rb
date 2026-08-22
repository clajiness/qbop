require_relative 'authentication_config'
require_relative 'authentication_routes'
require_relative 'oidc_http_configuration'
require_relative 'oidc_logger'
require_relative 'rodauth_configuration'

module Framework
  # Builds Rodauth middleware for qbop's optional browser authentication methods.
  class Authentication
    OIDC_REQUEST_PATH = OidcAuthentication::REQUEST_PATH
    OIDC_UNAUTHORIZED_MESSAGE = OidcAuthentication::UNAUTHORIZED_MESSAGE
    OIDC_FAILURE_MESSAGE = OidcAuthentication::FAILURE_MESSAGE

    def self.new(app, config: AuthenticationConfig.new)
      roda_app(config).new(app)
    end

    def self.rodauth(config: AuthenticationConfig.new)
      roda_app(config).rodauth
    end

    def self.roda_app(config = AuthenticationConfig.new)
      require_oidc_features if config.oidc_active?

      app = Class.new(Roda)
      app.plugin :middleware
      configure_rodauth(app, config)
      app.plugin :route_csrf, csrf_failure: :empty_403 # rubocop:disable Naming/VariableNumber
      configure_routes(app, config)
      app
    end

    def self.require_oidc_features
      require 'omniauth_openid_connect'
      require 'rodauth/features/omniauth'
      OidcHttpConfiguration.configure!
      OmniAuth.config.logger = OidcLogger.new(OmniAuth.config.logger) unless OmniAuth.config.logger.is_a?(OidcLogger)
    end
    private_class_method :require_oidc_features

    def self.configure_rodauth(app, config)
      app.plugin :rodauth do
        RodauthConfiguration.configure(self, config)
        OidcAuthentication.configure(self, config) if config.oidc_active?
      end
    end
    private_class_method :configure_rodauth

    def self.configure_routes(app, config)
      routes = AuthenticationRoutes.new(config)
      app.route do |r|
        authentication = rodauth
        env['rodauth'] = authentication
        env['qbop.auth_config'] = config
        routes.guard!(r, authentication)
        r.rodauth
      end
    end
    private_class_method :configure_routes
  end
end
