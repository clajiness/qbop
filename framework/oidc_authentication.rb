require_relative 'authentication_config'
require_relative 'oidc_identity'
require_relative 'oidc_provider_metadata'
require_relative 'oidc_session_configuration'

module Framework
  # Configures Rodauth's OIDC provider and qbop's identity-link/logout policy.
  class OidcAuthentication
    REQUEST_PATH = '/auth/openid_connect'.freeze
    UNAUTHORIZED_MESSAGE = 'This OpenID Connect account is not authorized to access qbop.'.freeze
    FAILURE_MESSAGE = 'OpenID Connect sign-in failed. Please try again.'.freeze

    def self.configure(auth, config)
      configure_provider(auth, config)
      configure_identity(auth, config)
      OidcSessionConfiguration.configure(
        auth, config, failure_message: FAILURE_MESSAGE, unauthorized_message: UNAUTHORIZED_MESSAGE
      )
    end

    def self.configure_provider(auth, config) # rubocop:disable Metrics/MethodLength
      auth.omniauth_provider secure_provider,
                             name: 'openid_connect',
                             issuer: config.oidc_issuer,
                             discovery: true,
                             scope: %i[openid email],
                             response_type: :code,
                             send_state: true,
                             require_state: true,
                             send_nonce: true,
                             pkce: true,
                             uid_field: 'sub',
                             client_options: {
                               identifier: config.oidc_client_id,
                               secret: config.oidc_client_secret,
                               redirect_uri: config.oidc_callback_url
                             }

      auth.omniauth_create_account? false
      auth.omniauth_failure_error_flash FAILURE_MESSAGE
      auth.omniauth_failure_redirect AuthenticationConfig::OIDC_FAILURE_PATH
      auth.omniauth_login_no_matching_account_error_flash UNAUTHORIZED_MESSAGE
      auth.omniauth_login_failure_redirect AuthenticationConfig::OIDC_FAILURE_PATH
    end
    private_class_method :configure_provider

    def self.secure_provider
      @secure_provider ||= Class.new(OmniAuth::Strategies::OpenIDConnect) do
        define_method(:config) do
          Framework::OidcProviderMetadata.validate!(super())
        end
      end
    end
    private_class_method :secure_provider

    def self.configure_identity(auth, config) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      auth.omniauth_identities_table OidcIdentity::TABLE
      auth.omniauth_identities_provider_column :issuer
      auth.omniauth_identities_uid_column :subject

      auth.auth_class_eval do
        define_method(:qbop_oidc_failure!) do |message|
          set_redirect_error_flash(message)
          redirect AuthenticationConfig::OIDC_FAILURE_PATH
        end
        private :qbop_oidc_failure!
      end

      auth.retrieve_omniauth_identity do |_provider, subject|
        db[OidcIdentity::TABLE].first(issuer: config.oidc_issuer, subject: subject)
      end
      auth.account_from_omniauth { db[accounts_table].first(login_column => omniauth_email) }
      auth.omniauth_identity_insert_hash do
        {
          omniauth_identities_account_id_column => account_id,
          issuer: config.oidc_issuer,
          subject: omniauth_uid
        }
      end
      auth.create_omniauth_identity do
        identity_id = omniauth_identities_ds.insert(omniauth_identity_insert_hash)
        @omniauth_identity = { omniauth_identities_id_column => identity_id }
      rescue Sequel::UniqueConstraintViolation
        qbop_oidc_failure!(UNAUTHORIZED_MESSAGE)
      end
    end
    private_class_method :configure_identity
  end
end
