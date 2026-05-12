module Service
  # Qbit is a class responsible for interacting with the qBittorrent Web API.
  class Qbit
    def initialize(config)
      @config = config
      @conn = faraday_conn(config)
    end

    def qbt_auth_login # rubocop:disable Metrics/MethodLength
      response = @conn.post do |req|
        req.url '/api/v2/auth/login'
        req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
        req.body = URI.encode_www_form(
          {
            'username': @config[:qbit_user],
            'password': @config[:qbit_pass]
          }
        )
      end

      response['set-cookie'].split(';')[0]
    end

    def qbt_app_preferences
      @auth_headers = auth_headers
      response = @conn.get do |req|
        req.url '/api/v2/app/preferences'
        authenticate(req, @auth_headers)
      end

      JSON.parse(response.body)['listen_port']
    end

    def qbt_app_set_preferences(forwarded_port)
      @conn.post do |req|
        req.url '/api/v2/app/setPreferences'
        authenticate(req, @auth_headers || auth_headers)
        req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
        req.body = URI.encode_www_form({ 'json': "{\"listen_port\": #{forwarded_port.to_i}}" })
      end
    end

    private

    def authenticate(req, headers)
      headers.each do |key, value|
        req.headers[key] = value
      end
    end

    def auth_headers
      if @config[:qbit_api_key]
        { 'Authorization' => "Bearer #{@config[:qbit_api_key]}" }
      else
        { 'Cookie' => qbt_auth_login }
      end
    end

    def faraday_conn(config)
      Faraday.new(
        url: config[:qbit_addr],
        ssl: { verify: false }
      )
    end
  end
end
