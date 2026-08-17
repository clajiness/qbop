module Framework
  # Rodauth middleware for qbop's browser authentication.
  class Authentication < Roda
    plugin :middleware

    plugin :rodauth do
      db { DB }
      enable :login, :logout, :create_account, :internal_request

      prefix ''
      create_account_route 'setup'
      require_login_confirmation? false

      login_label 'Email'
      login_page_title 'Sign in to qbop'
      login_button 'Sign in'
      create_account_page_title 'Welcome to qbop'
      create_account_button 'Create account'

      before_login_route do
        helpers = Service::Helpers.new
        web_auth_enabled = helpers.true?(helpers.env_variables[:web_auth_enabled])
        redirect '/setup' if web_auth_enabled && db[accounts_table].count.zero?
      end
    end
    plugin :route_csrf, csrf_failure: :empty_403 # rubocop:disable Naming/VariableNumber

    route do |r|
      env['rodauth'] = rodauth

      if r.path == '/setup'
        helpers = Service::Helpers.new
        web_auth_enabled = helpers.true?(helpers.env_variables[:web_auth_enabled])
        r.halt [404, {}, []] unless web_auth_enabled && DB[:accounts].count.zero?
      end

      r.rodauth
    end
  end
end
