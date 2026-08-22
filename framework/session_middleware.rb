require 'rack/request'
require 'rack/session/cookie'

module Framework
  # Adds an encrypted cookie session and marks it Secure for HTTPS requests.
  class SessionMiddleware
    COOKIE_OPTIONS = {
      key: 'qbop.session',
      path: '/',
      httponly: true,
      same_site: :lax
    }.freeze

    def initialize(app, secret:, force_secure: false)
      @http = Rack::Session::Cookie.new(app, **COOKIE_OPTIONS, secrets: [secret], secure: false)
      @https = Rack::Session::Cookie.new(app, **COOKIE_OPTIONS, secrets: [secret], secure: true)
      @force_secure = force_secure
    end

    def call(env)
      return @https.call(forced_https_environment(env)) if @force_secure

      (Rack::Request.new(env).ssl? ? @https : @http).call(env)
    end

    private

    def forced_https_environment(env)
      env.merge('HTTPS' => 'on', 'rack.url_scheme' => 'https')
    end
  end
end
