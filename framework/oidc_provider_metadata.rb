require 'uri'

module Framework
  # Rejects discovery metadata that would send browser or back-channel OIDC traffic to unsafe URLs.
  class OidcProviderMetadata
    class Invalid < StandardError; end

    REQUIRED_ENDPOINTS = %i[authorization_endpoint token_endpoint userinfo_endpoint jwks_uri].freeze
    OPTIONAL_ENDPOINTS = [:end_session_endpoint].freeze
    MAX_ENDPOINT_BYTES = 2048
    MAX_LOGOUT_ENDPOINT_BYTES = 384

    def self.validate!(metadata)
      REQUIRED_ENDPOINTS.each { |name| validate_endpoint!(name, metadata.public_send(name), required: true) }
      OPTIONAL_ENDPOINTS.each { |name| validate_endpoint!(name, metadata.public_send(name), required: false) }
      metadata
    end

    def self.validate_endpoint!(name, value, required:)
      raise Invalid, "OIDC discovery #{name} is missing" if value.nil? && required
      return if value.nil?

      max_bytes = name == :end_session_endpoint ? MAX_LOGOUT_ENDPOINT_BYTES : MAX_ENDPOINT_BYTES
      return if value.is_a?(String) && valid_https_url?(value, max_bytes)

      raise Invalid, "OIDC discovery #{name} is invalid"
    end
    private_class_method :validate_endpoint!

    def self.valid_https_url?(value, max_bytes)
      return false if value.empty? || value.bytesize > max_bytes

      uri = URI.parse(value)
      uri.scheme == 'https' && !uri.host.to_s.empty? && !uri.userinfo && !uri.fragment
    rescue URI::InvalidURIError
      false
    end
    private_class_method :valid_https_url?
  end
end
