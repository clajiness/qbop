require 'uri'

module Framework
  # Builds a fixed-destination RP-Initiated Logout URL from discovery metadata.
  class OidcLogout
    MAX_ENDPOINT_BYTES = 384

    def self.url(endpoint:, id_token:, post_logout_redirect_uri:)
      return if endpoint.to_s.empty? || id_token.to_s.empty?
      return unless valid_endpoint?(endpoint)

      uri = URI.parse(endpoint)
      uri.query = logout_query(uri, id_token, post_logout_redirect_uri)
      uri.to_s
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    def self.logout_query(uri, id_token, post_logout_redirect_uri)
      query = URI.decode_www_form(uri.query.to_s)
      query.reject! { |key, _value| %w[id_token_hint post_logout_redirect_uri].include?(key) }
      query << ['id_token_hint', id_token]
      query << ['post_logout_redirect_uri', post_logout_redirect_uri]
      URI.encode_www_form(query)
    end
    private_class_method :logout_query

    def self.valid_endpoint?(endpoint)
      return false if endpoint.to_s.empty? || endpoint.bytesize > MAX_ENDPOINT_BYTES

      secure_http_url?(URI.parse(endpoint))
    rescue URI::InvalidURIError
      false
    end

    def self.secure_http_url?(uri)
      return false unless uri.host && !uri.userinfo && !uri.fragment
      return true if uri.scheme == 'https'

      uri.scheme == 'http' && loopback_host?(uri.host)
    end
    private_class_method :secure_http_url?

    def self.loopback_host?(host)
      return true if ['localhost', '[::1]'].include?(host)

      parts = host.split('.')
      parts.length == 4 && parts.first == '127' && parts.all? do |part|
        part.match?(/\A\d{1,3}\z/) && part.to_i <= 255
      end
    end
    private_class_method :loopback_host?
  end
end
