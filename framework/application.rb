module Framework
  # Builds qbop's Rack middleware stack around its Sinatra and Grape apps.
  class Application
    def self.build(session_secret_path: 'data/session_secret.txt') # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      helpers = Service::Helpers.new
      session_secret = SessionSecret.load_or_create(session_secret_path)

      Rack::Builder.new do
        if helpers.env_variables[:basic_auth_enabled] == 'true'
          use Rack::Auth::Basic, 'Restricted Content' do |username, password|
            username.eql?(helpers.env_variables[:basic_auth_user]) &&
              password.eql?(helpers.env_variables[:basic_auth_pass])
          end
        end

        use SessionMiddleware, secret: session_secret
        use Authentication
        run Rack::Cascade.new([Web, API])
      end.to_app
    end
  end
end
