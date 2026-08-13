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

    def initialize(app, secret:)
      @http = Rack::Session::Cookie.new(app, **COOKIE_OPTIONS, secret: secret, secure: false)
      @https = Rack::Session::Cookie.new(app, **COOKIE_OPTIONS, secret: secret, secure: true)
    end

    def call(env)
      middleware = Rack::Request.new(env).ssl? ? @https : @http
      middleware.call(env)
    end
  end
end
