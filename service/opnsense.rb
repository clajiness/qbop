module Service
  # The Opnsense class provides methods to interact with the OPNsense firewall API.
  class Opnsense
    def initialize(config)
      @config = config
      @conn = faraday_conn(config)
    end

    def get_alias_uuid
      response = @conn.get do |req|
        req.url "/api/firewall/alias/get_alias_uuid/#{@config[:opnsense_alias_name]}"
      end

      JSON.parse(response.body)['uuid']
    end

    def get_alias_value(uuid)
      response = @conn.get do |req|
        req.url '/api/firewall/alias/get'
      end

      alias_content = JSON.parse(response.body).dig('alias', 'aliases', 'alias', uuid, 'content')
      alias_content.values[0]['value'].to_i
    end

    def set_alias_value(forwarded_port, uuid)
      @conn.post do |req|
        req.url "/api/firewall/alias/set_item/#{uuid}"
        req.headers['Content-Type'] = 'application/json'
        req.body = { 'alias': { 'content': forwarded_port } }.to_json
      end
    end

    def apply_changes
      @conn.post do |req|
        req.url '/api/firewall/alias/reconfigure'
      end
    end

    private

    def faraday_conn(config)
      Faraday.new(
        url: config[:opnsense_interface_addr],
        ssl: { verify: false }
      ) do |faraday|
        faraday.request :authorization, :basic, config[:opnsense_api_key], config[:opnsense_api_secret]
      end
    end
  end
end
