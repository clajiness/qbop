require 'uri'

module Framework
  # Parses and validates browser authentication configuration once at startup.
  class AuthenticationConfig
    class Error < ArgumentError; end

    OIDC_CALLBACK_PATH = '/auth/openid_connect/callback'.freeze
    OIDC_FAILURE_PATH = '/oidc/error'.freeze
    LOGGED_OUT_PATH = '/logged-out'.freeze

    attr_reader :oidc_issuer, :oidc_client_id, :oidc_client_secret, :oidc_public_url

    def initialize(env = ENV)
      @web_auth_enabled = boolean_setting(env, 'WEB_AUTH_ENABLED', true)
      @oidc_enabled = boolean_setting(env, 'OIDC_ENABLED', false)
      @oidc_auto_redirect = boolean_setting(env, 'OIDC_AUTO_REDIRECT', false)
      @local_login_enabled = boolean_setting(env, 'LOCAL_LOGIN_ENABLED', true)
      read_oidc_settings(env)
      validate!
    end

    def web_auth_enabled? = @web_auth_enabled

    def oidc_enabled? = @oidc_enabled

    def oidc_active? = web_auth_enabled? && oidc_enabled?

    def oidc_auto_redirect? = @oidc_auto_redirect

    def oidc_auto_redirect_active? = oidc_auto_redirect? && !local_login_enabled?

    def local_login_enabled? = @local_login_enabled

    def oidc_callback_url
      "#{oidc_public_url}#{OIDC_CALLBACK_PATH}"
    end

    def oidc_logout_callback_url
      "#{oidc_public_url}#{LOGGED_OUT_PATH}"
    end

    def force_secure_cookie?
      oidc_active? && URI.parse(oidc_public_url).scheme == 'https'
    end

    private

    def validate!
      return unless web_auth_enabled?

      validate_login_modes!
      validate_oidc! if oidc_enabled?
    end

    def boolean_setting(env, name, default)
      env.fetch(name, default.to_s).to_s.downcase == 'true'
    end

    def read_oidc_settings(env)
      @oidc_issuer = env['OIDC_ISSUER']&.strip
      @oidc_client_id = env['OIDC_CLIENT_ID']&.strip
      @oidc_client_secret = env['OIDC_CLIENT_SECRET']&.strip
      @oidc_public_url = env['OIDC_PUBLIC_URL']&.strip
    end

    def validate_login_modes!
      raise Error, 'OIDC_AUTO_REDIRECT requires OIDC_ENABLED=true' if oidc_auto_redirect? && !oidc_enabled?
      return if local_login_enabled? || oidc_enabled?

      raise Error, 'LOCAL_LOGIN_ENABLED=false requires OIDC_ENABLED=true'
    end

    def validate_oidc!
      require_setting!('OIDC_ISSUER', oidc_issuer)
      require_setting!('OIDC_CLIENT_ID', oidc_client_id)
      require_setting!('OIDC_CLIENT_SECRET', oidc_client_secret)
      require_setting!('OIDC_PUBLIC_URL', oidc_public_url)
      validate_url!('OIDC_ISSUER', oidc_issuer, origin_only: false, allow_loopback_http: false)
      validate_url!('OIDC_PUBLIC_URL', oidc_public_url, origin_only: true, allow_loopback_http: true)
    end

    def require_setting!(name, value)
      raise Error, "#{name} must be set when OIDC is enabled" if value.nil? || value.empty?
    end

    def validate_url!(name, value, origin_only:, allow_loopback_http:)
      uri = URI.parse(value)
      unless valid_url?(uri, origin_only: origin_only, allow_loopback_http: allow_loopback_http)
        raise Error, "#{name} must be an HTTPS URL without credentials, query, or fragment"
      end

      @oidc_public_url = value.delete_suffix('/') if name == 'OIDC_PUBLIC_URL'
    rescue URI::InvalidURIError
      raise Error, "#{name} must be a valid URL"
    end

    def valid_url?(uri, origin_only:, allow_loopback_http:)
      http_url?(uri) && clean_url?(uri) && valid_path?(uri, origin_only) &&
        secure_url?(uri, allow_loopback_http)
    end

    def http_url?(uri)
      %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?
    end

    def clean_url?(uri)
      !uri.userinfo && !uri.query && !uri.fragment
    end

    def valid_path?(uri, origin_only)
      !origin_only || uri.path.empty? || uri.path == '/'
    end

    def secure_url?(uri, allow_loopback_http)
      uri.scheme == 'https' || (allow_loopback_http && loopback_host?(uri.host))
    end

    def loopback_host?(host)
      host == 'localhost' || host == '[::1]' || loopback_ipv4?(host)
    end

    def loopback_ipv4?(host)
      parts = host.split('.')
      parts.length == 4 && parts.first == '127' && parts.all? do |part|
        part.match?(/\A\d{1,3}\z/) && part.to_i <= 255
      end
    end
  end
end
