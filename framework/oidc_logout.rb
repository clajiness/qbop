require 'uri'

module Framework
  # Builds a fixed-destination RP-Initiated Logout URL from discovery metadata.
  class OidcLogout
    def self.url(endpoint:, id_token:, post_logout_redirect_uri:)
      return if endpoint.to_s.empty? || id_token.to_s.empty?

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
  end
end
