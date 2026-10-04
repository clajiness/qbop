require 'uri'

module Service
  # Shared base-URL contract for Gluetun requests and configuration displays.
  module GluetunUrl
    class InvalidBaseUrl < StandardError; end

    def self.parse(address)
      uri = URI.parse(address)
      unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
        raise InvalidBaseUrl, 'GLUETUN_ADDR must be an HTTP(S) base URL'
      end
      raise InvalidBaseUrl, 'GLUETUN_ADDR port must be in 1-65535' unless (1..65_535).cover?(uri.port)

      raise InvalidBaseUrl, 'GLUETUN_ADDR must not contain a query string or fragment' if uri.query || uri.fragment

      uri
    end
  end
end
