module Framework
  # Builds qbop's Rack middleware stack around its Sinatra and Grape apps.
  class Application
    def self.build(session_secret_path: 'data/session_secret.txt')
      session_secret = SessionSecret.load_or_create(session_secret_path)
      web = web_app(session_secret)
      api = API

      lambda do |env|
        path = env.fetch('PATH_INFO', '')
        app = path == '/api' || path.start_with?('/api/') ? api : web
        app.call(env)
      end
    end

    def self.web_app(session_secret)
      Rack::Builder.new do
        use SessionMiddleware, secret: session_secret
        use Authentication
        run Web
      end.to_app
    end
    private_class_method :web_app
  end
end
