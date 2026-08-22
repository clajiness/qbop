module Framework
  # Applies qbop's existing local-account settings to a Rodauth configuration.
  class RodauthConfiguration
    FEATURES = %i[login logout create_account change_login change_password internal_request].freeze

    def self.configure(auth, config)
      auth.db { DB }
      auth.enable(*(config.oidc_active? ? FEATURES + [:omniauth] : FEATURES))
      configure_routes(auth)
      configure_labels(auth)
      configure_views(auth)
      auth.before_login_route do
        redirect '/setup' if config.web_auth_enabled? && db[accounts_table].count.zero?
      end
    end

    def self.configure_routes(auth)
      auth.prefix ''
      auth.create_account_route 'setup'
      auth.change_login_route 'account/change-email'
      auth.change_password_route 'account/change-password'
      auth.change_login_redirect '/account'
      auth.change_password_redirect '/account'
      auth.require_login_confirmation? false
    end
    private_class_method :configure_routes

    def self.configure_labels(auth) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      auth.login_label 'email'
      auth.auth_class_eval do
        define_method(:login_field_autocomplete_value) { 'username' }
      end
      auth.login_does_not_meet_requirements_message do
        "invalid email#{": #{login_requirement_message}" if login_requirement_message}"
      end
      auth.password_label 'password'
      auth.password_confirm_label 'confirm password'
      auth.login_page_title 'sign in to qbop'
      auth.login_button 'sign in'
      auth.login_notice_flash 'you have been logged in'
      auth.login_error_flash 'there was an error logging in'
      auth.require_login_error_flash 'please login to continue'
      auth.create_account_page_title 'welcome to qbop'
      auth.create_account_button 'create account'
      auth.create_account_notice_flash 'your account has been created'
      auth.create_account_error_flash 'there was an error creating your account'
      auth.change_login_page_title 'change email'
      auth.change_login_button 'change email'
      auth.change_login_notice_flash 'email changed successfully'
      auth.change_login_error_flash 'there was an error changing your email'
      auth.same_as_current_login_message 'same as current email'
      auth.change_password_page_title 'change password'
      auth.change_password_button 'change password'
      auth.change_password_notice_flash 'password changed successfully'
      auth.change_password_error_flash 'there was an error changing your password'
      auth.new_password_label 'new password'
      auth.logout_page_title 'sign out'
      auth.logout_button 'sign out'
      auth.logout_notice_flash 'you have been logged out'
    end
    private_class_method :configure_labels

    def self.configure_views(auth) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      auth.change_login_view do
        if request.post?
          error = field_error(password_param) || field_error(login_param) || change_login_error_flash
          set_redirect_error_flash(error)
        end
        redirect change_login_redirect
      end

      auth.change_password_view do
        if request.post?
          error = field_error(password_param) || field_error(new_password_param) || change_password_error_flash
          set_redirect_error_flash(error)
        end
        redirect change_password_redirect
      end
    end
    private_class_method :configure_views
  end
end
