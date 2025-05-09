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

    def qbt_app_preferences(sid)
      response = @conn.get do |req|
        req.url '/api/v2/app/preferences'
        req.headers['Cookie'] = sid
      end

      JSON.parse(response.body)['listen_port']
    end

    def qbt_app_set_preferences(forwarded_port, sid)
      @conn.post do |req|
        req.url '/api/v2/app/setPreferences'
        req.headers['Cookie'] = sid
        req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
        req.body = URI.encode_www_form({ 'json': "{\"listen_port\": #{forwarded_port.to_i}}" })
      end
    end

    private

    def faraday_conn(config)
      Faraday.new(
        url: config[:qbit_addr],
        ssl: { verify: false }
      )
    end
  end
end
