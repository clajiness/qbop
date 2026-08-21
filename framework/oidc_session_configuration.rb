require_relative 'authentication_config'
require_relative 'oidc_identity'
require_relative 'oidc_logout'

module Framework
  # Applies OIDC callback-linking and session/logout behavior to Rodauth.
  class OidcSessionConfiguration
    ID_TOKEN_SESSION_KEY = :qbop_oidc_id_token
    END_SESSION_ENDPOINT_KEY = :qbop_oidc_end_session_endpoint
    ISSUER_SESSION_KEY = :qbop_oidc_issuer
    MAX_ID_TOKEN_BYTES = 1800
    UNTRUSTED_CALLBACK_PARAMETERS = %w[code_verifier nonce redirect_uri].freeze

    def self.configure(auth, config, failure_message:, unauthorized_message:)
      configure_callback_parameters(auth)
      configure_callback(auth, config, failure_message, unauthorized_message)
      configure_logout(auth, config)
    end

    def self.configure_callback_parameters(auth)
      auth.omniauth_before_callback_phase do
        UNTRUSTED_CALLBACK_PARAMETERS.each { |name| omniauth_strategy.params.delete(name) }
      end
    end
    private_class_method :configure_callback_parameters

    def self.configure_callback(auth, config, failure_message, unauthorized_message) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
      invalid_authorized_party = method(:invalid_authorized_party?)
      auth.before_omniauth_callback_route do
        redirect '/setup' if db[accounts_table].count.zero?

        raw_info = omniauth_extra&.fetch('raw_info', nil)
        subject = raw_info&.fetch('sub', nil)
        id_token = omniauth_credentials&.fetch('id_token', nil).to_s
        invalid_protocol_identity = id_token.empty? || id_token.bytesize > MAX_ID_TOKEN_BYTES
        invalid_protocol_identity ||= invalid_authorized_party.call(raw_info, config.oidc_client_id)
        qbop_oidc_failure!(failure_message) if invalid_protocol_identity

        identity = OidcIdentity.new(db: db, issuer: config.oidc_issuer)
        next if identity.find(subject)

        identity.authorize_new_link!(
          subject: subject,
          email: omniauth_email,
          email_verified: omniauth_info&.fetch('email_verified', nil)
        )
      rescue OidcIdentity::Unauthorized
        qbop_oidc_failure!(unauthorized_message)
      end

      auth.after_login do
        next unless authenticated_by&.include?('omniauth')

        set_session_value(ID_TOKEN_SESSION_KEY, omniauth_credentials.fetch('id_token'))
        set_session_value(ISSUER_SESSION_KEY, config.oidc_issuer)
        endpoint = omniauth_strategy.options.client_options.end_session_endpoint
        set_session_value(END_SESSION_ENDPOINT_KEY, endpoint) if endpoint
      end
    end
    private_class_method :configure_callback

    def self.invalid_authorized_party?(raw_info, client_id)
      audience = raw_info&.fetch('aud', nil)
      authorized_party = raw_info&.fetch('azp', nil)
      return false unless authorized_party || audience.is_a?(Array) && audience.length > 1

      authorized_party != client_id
    end
    private_class_method :invalid_authorized_party?

    def self.configure_logout(auth, config) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      auth.uses_instance_variables :@qbop_oidc_logout
      auth.before_logout do
        next unless authenticated_by&.include?('omniauth')

        @qbop_oidc_logout = {
          id_token: session[ID_TOKEN_SESSION_KEY],
          endpoint: session[END_SESSION_ENDPOINT_KEY]
        }
      end

      auth.logout_response do
        if @qbop_oidc_logout
          logout_url = OidcLogout.url(
            endpoint: @qbop_oidc_logout[:endpoint],
            id_token: @qbop_oidc_logout[:id_token],
            post_logout_redirect_uri: config.oidc_logout_callback_url
          )
          redirect(logout_url || AuthenticationConfig::LOGGED_OUT_PATH)
        end

        set_notice_flash logout_notice_flash
        redirect logout_redirect
      end
    end
    private_class_method :configure_logout
  end
end
