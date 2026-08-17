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

      login_label 'email'
      password_label 'password'
      password_confirm_label 'confirm password'
      login_page_title 'sign in to qbop'
      login_button 'sign in'
      login_notice_flash 'you have been logged in'
      login_error_flash 'there was an error logging in'
      require_login_error_flash 'please login to continue'
      create_account_page_title 'welcome to qbop'
      create_account_button 'create account'
      create_account_notice_flash 'your account has been created'
      create_account_error_flash 'there was an error creating your account'
      logout_page_title 'sign out'
      logout_button 'sign out'
      logout_notice_flash 'you have been logged out'

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
