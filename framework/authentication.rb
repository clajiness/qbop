module Framework
  # Rodauth middleware for qbop's browser authentication.
  class Authentication < Roda
    plugin :middleware

    plugin :rodauth do # rubocop:disable Metrics/BlockLength
      db { DB }
      enable :login, :logout, :create_account, :change_login, :change_password, :internal_request

      prefix ''
      create_account_route 'setup'
      change_login_route 'account/change-email'
      change_password_route 'account/change-password'
      change_login_redirect '/account'
      change_password_redirect '/account'
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
      change_login_page_title 'change email'
      change_login_button 'change email'
      change_login_notice_flash 'your email has been changed'
      change_login_error_flash 'there was an error changing your email'
      same_as_current_login_message 'same as current email'
      change_password_page_title 'change password'
      change_password_button 'change password'
      change_password_notice_flash 'your password has been changed'
      change_password_error_flash 'there was an error changing your password'
      new_password_label 'new password'
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
      elsif r.path == '/account' || r.path.start_with?('/account/')
        helpers = Service::Helpers.new
        web_auth_enabled = helpers.true?(helpers.env_variables[:web_auth_enabled])
        r.halt [404, {}, []] unless web_auth_enabled
      end

      r.rodauth
    end
  end
end
