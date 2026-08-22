require_relative 'oidc_authentication'

module Framework
  # Rejects browser-authentication routes that are disabled for this process.
  class AuthenticationRoutes
    LOCAL_SESSION_METHODS = %w[password create_account].freeze

    def initialize(config)
      @config = config
    end

    def guard!(request, authentication)
      guard_session_method!(request, authentication)
      path = request.path
      guard_setup!(request, path)
      guard_account!(request, path)
      guard_local_login!(request, path)
      guard_oidc!(request, path)
    end

    private

    def guard_session_method!(request, authentication)
      return unless @config.web_auth_enabled?
      return unless authentication.logged_in?
      return if valid_session_method?(authentication)

      authentication.clear_session
      request.redirect('/login')
    end

    def valid_session_method?(authentication)
      case single_session_method(authentication)
      when *LOCAL_SESSION_METHODS
        @config.local_login_enabled?
      when 'autologin'
        valid_setup_session?(authentication)
      when 'omniauth'
        valid_oidc_session?(authentication)
      else
        false
      end
    end

    def single_session_method(authentication)
      methods = authentication.authenticated_by
      methods.first if methods.is_a?(Array) && methods.length == 1
    end

    def valid_setup_session?(authentication)
      @config.local_login_enabled? && authentication.autologin_type == 'create_account'
    end

    def valid_oidc_session?(authentication)
      @config.oidc_active? &&
        authentication.session[OidcSessionConfiguration::ISSUER_SESSION_KEY] == @config.oidc_issuer
    end

    def guard_setup!(request, path)
      return unless path == '/setup'
      return if @config.web_auth_enabled? && DB[:accounts].count.zero?

      request.halt [404, {}, []]
    end

    def guard_account!(request, path)
      return unless path == '/account' || path.start_with?('/account/')

      request.halt [404, {}, []] unless @config.web_auth_enabled?
    end

    def guard_local_login!(request, path)
      return unless path == '/login' && request.post?

      request.halt [404, {}, []] unless @config.local_login_enabled?
    end

    def guard_oidc!(request, path)
      oidc_path = OidcAuthentication::REQUEST_PATH
      return unless path == oidc_path || path.start_with?("#{oidc_path}/")

      request.halt [404, {}, []] unless @config.oidc_active?
      request.redirect('/setup') if path == oidc_path && DB[:accounts].count.zero?
    end
  end
end
