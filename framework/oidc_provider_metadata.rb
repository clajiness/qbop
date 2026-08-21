require 'json'
require 'uri'

module Framework
  # Rejects discovery metadata that would send browser or back-channel OIDC traffic to unsafe URLs.
  class OidcProviderMetadata
    class Invalid < StandardError; end

    REQUIRED_ENDPOINTS = %i[authorization_endpoint token_endpoint userinfo_endpoint jwks_uri].freeze
    OPTIONAL_ENDPOINTS = [:end_session_endpoint].freeze
    MAX_ENDPOINT_BYTES = 2048
    MAX_DOCUMENT_BYTES = 65_536

    def self.validate!(metadata)
      validate_document_size!(metadata)
      REQUIRED_ENDPOINTS.each { |name| validate_endpoint!(name, metadata.public_send(name), required: true) }
      OPTIONAL_ENDPOINTS.each { |name| validate_endpoint!(name, metadata.public_send(name), required: false) }
      metadata
    end

    def self.validate_document_size!(metadata)
      raw = metadata.respond_to?(:raw) ? metadata.raw : metadata.as_json
      raise Invalid, 'OIDC discovery document is too large' if JSON.generate(raw).bytesize > MAX_DOCUMENT_BYTES
    end
    private_class_method :validate_document_size!

    def self.validate_endpoint!(name, value, required:)
      raise Invalid, "OIDC discovery #{name} is missing" if value.nil? && required
      return if value.nil?
      raise Invalid, "OIDC discovery #{name} is invalid" unless value.is_a?(String) && valid_https_url?(value)
    end
    private_class_method :validate_endpoint!

    def self.valid_https_url?(value)
      return false if value.empty? || value.bytesize > MAX_ENDPOINT_BYTES

      uri = URI.parse(value)
      uri.scheme == 'https' && !uri.host.to_s.empty? && !uri.userinfo && !uri.fragment
    rescue URI::InvalidURIError
      false
    end
    private_class_method :valid_https_url?
  end
end
