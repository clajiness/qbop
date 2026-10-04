module Service
  # Observes a single forwarded port through Gluetun's control API.
  class Gluetun
    REQUEST_TIMEOUT = { open_timeout: 5, timeout: 10 }.freeze

    class PortError < StandardError; end

    def initialize(config)
      @conn = faraday_conn(config)
    end

    def name
      'gluetun'
    end

    def current_port
      response = @conn.get('/v1/portforward')
      raise PortError, "Gluetun control API returned HTTP #{response.status}" unless response.status.between?(200, 299)

      parse_port(response.body)
    rescue Faraday::Error => e
      # Transport messages may contain credentials or request details.
      raise PortError, "Gluetun control API request failed (#{e.class})"
    end

    private

    def faraday_conn(config)
      Faraday.new(
        url: config[:gluetun_addr],
        ssl: { verify: config[:gluetun_ssl_verify] },
        request: REQUEST_TIMEOUT
      ) { |faraday| authenticate(faraday, config) }
    end

    def authenticate(faraday, config)
      api_key = config[:gluetun_api_key]
      user = config[:gluetun_user]
      password = config[:gluetun_pass]
      if !api_key.to_s.strip.empty?
        faraday.headers['X-API-Key'] = api_key
      elsif user && password
        faraday.request :authorization, :basic, user, password
      end
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
      raise PortError, 'Gluetun control API returned malformed JSON'
    end
  end
end
