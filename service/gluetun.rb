require_relative 'gluetun_url'

module Service
  # Observes a single forwarded port through Gluetun's control API.
  class Gluetun
    REQUEST_TIMEOUT = { open_timeout: 5, timeout: 10 }.freeze

    class PortError < StandardError; end

    def initialize(config)
      @conn = faraday_conn(config)
    rescue PortError
      raise
    rescue StandardError => e
      raise PortError, "Gluetun configuration failed (#{e.class})", cause: nil
    end

    def name
      'gluetun'
    end

    def current_port
      response = @conn.get('v1/portforward')
      raise PortError, "Gluetun control API returned HTTP #{response.status}" unless response.status.between?(200, 299)

      parse_port(response.body)
    rescue PortError
      raise
    rescue StandardError => e
      # Client errors and their causes may contain credentials or request details.
      raise PortError, "Gluetun control API request failed (#{e.class})", cause: nil
    end

    private

    def faraday_conn(config)
      Faraday.new(
        url: base_url(config[:gluetun_addr]),
        ssl: { verify: config[:gluetun_ssl_verify] },
        request: REQUEST_TIMEOUT
      ) { |faraday| authenticate(faraday, config) }
    end

    def base_url(address)
      uri = GluetunUrl.parse(address)
      uri.user = nil
      uri.to_s
    rescue GluetunUrl::InvalidBaseUrl => e
      raise PortError, e.message, cause: nil
    end

    def authenticate(faraday, config)
      # Use only the explicit authentication settings.
      faraday.headers.delete('Authorization')
      api_key, user, password = config.values_at(:gluetun_api_key, :gluetun_user, :gluetun_pass)
      if !api_key.to_s.strip.empty?
        validate_credential(api_key, 'GLUETUN_API_KEY')
        faraday.headers['X-API-Key'] = api_key
      else
        authenticate_basic(faraday, user, password)
      end
    end

    def authenticate_basic(faraday, user, password)
      user_blank = blank_credential?(user)
      password_blank = blank_credential?(password)
      return if user_blank && password_blank

      if user_blank || password_blank
        raise PortError, 'GLUETUN_USER and GLUETUN_PASS must both be configured for Basic authentication', cause: nil
      end

      validate_credential(user, 'GLUETUN_USER')
      validate_credential(password, 'GLUETUN_PASS')
      faraday.request :authorization, :basic, user, password
    end

    def blank_credential?(value)
      value.nil? || (value.is_a?(String) && value.valid_encoding? && value.strip.empty?)
    end

    def validate_credential(value, setting)
      return if value.is_a?(String) && value.valid_encoding? && !value.match?(/[[:cntrl:]]/)

      raise PortError, "#{setting} must be a string without control characters"
    end

    def single_port_list?(ports, port)
      ports.is_a?(Array) && ports.size == 1 && ports.first.is_a?(Integer) && ports.first == port
    end

    def parse_port(body)
      result = JSON.parse(body)
      unless result.is_a?(Hash) && result['port'].is_a?(Integer) && result['port'].between?(1, 65_535)
        raise PortError, 'Gluetun response did not contain a valid integer port in 1-65535'
      end
      if result.key?('ports') && !single_port_list?(result['ports'], result['port'])
        raise PortError, 'Gluetun response must contain exactly one forwarded port'
      end

      result['port']
    rescue JSON::ParserError
      raise PortError, 'Gluetun control API returned malformed JSON', cause: nil
    end
  end
end
