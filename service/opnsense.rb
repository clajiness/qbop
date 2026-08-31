module Service
  # The Opnsense class provides methods to interact with the OPNsense firewall API.
  class Opnsense # rubocop:disable Metrics/ClassLength
    REQUEST_TIMEOUT = { open_timeout: 5, timeout: 10 }.freeze
    WIREGUARD_API_TIMEOUT = 30
    WIREGUARD_RECONFIGURE_TIMEOUT = 300
    OPN_UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    class WireguardImportError < StandardError; end

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

    def wireguard_targets
      validate_wireguard_config

      {
        instances: wireguard_target_records('server'),
        peers: wireguard_target_records('client')
      }
    rescue WireguardImportError
      raise
    rescue StandardError => e
      raise WireguardImportError, "could not load opnsense wireguard targets: #{e.message}"
    end

    def validate_wireguard_config
      settings = {
        'OPN_INTERFACE_ADDR' => @config[:opnsense_interface_addr],
        'OPN_API_KEY' => @config[:opnsense_api_key],
        'OPN_API_SECRET' => @config[:opnsense_api_secret]
      }
      missing = settings.filter_map { |name, value| name if value.to_s.strip.empty? }
      return if missing.empty?

      raise WireguardImportError, "missing opnsense configuration: #{missing.join(', ')}"
    end

    def wireguard_instance(uuid)
      get_wireguard_record('server', uuid)
    end

    def wireguard_peer(uuid)
      get_wireguard_record('client', uuid)
    end

    def save_wireguard_instance(uuid, payload)
      response = request_json(
        :post, "/api/wireguard/server/set_server/#{uuid}", payload: { 'server' => payload }
      )
      expect_result(response, 'saved', 'update the wireguard instance')
    end

    def save_wireguard_peer(uuid, payload)
      response = request_json(
        :post, "/api/wireguard/client/set_client/#{uuid}", payload: { 'client' => payload }
      )
      expect_result(response, 'saved', 'update the wireguard peer')
    end

    def reconfigure_wireguard
      response = request_json(
        :post,
        '/api/wireguard/service/reconfigure',
        timeout: WIREGUARD_RECONFIGURE_TIMEOUT
      )
      expect_result(response, 'ok', 'apply the wireguard configuration')
    end

    def wireguard_runtime
      response = request_json(
        :get, '/api/wireguard/service/show', query: { 'rowCount' => '-1' }
      )
      records = response['rows']
      return records if records.is_a?(Array)

      raise WireguardImportError, 'opnsense did not return wireguard runtime records'
    end

    private

    def wireguard_target_records(type)
      endpoint = type == 'server' ? 'search_server' : 'search_client'
      response = request_json(
        :get, "/api/wireguard/#{type}/#{endpoint}", query: { 'rowCount' => '-1' }
      )
      records = response.fetch('rows', []).filter_map { |row| wireguard_target_record(type, row) }
      records.sort_by { |record| record[:name].downcase }
    end

    def wireguard_target_record(type, row)
      return unless row['uuid'].to_s.match?(OPN_UUID) && !row['name'].to_s.empty?

      record = { uuid: row['uuid'], name: row['name'] }
      record[:interface] = row['interface'] if type == 'server' && !row['interface'].to_s.empty?
      record
    end

    def get_wireguard_record(type, uuid)
      endpoint = type == 'server' ? 'get_server' : 'get_client'
      response = request_json(:get, "/api/wireguard/#{type}/#{endpoint}/#{uuid}")
      response.fetch(type) do
        subject = type == 'server' ? 'instance' : 'peer'
        raise WireguardImportError, "opnsense did not return the existing #{subject}"
      end
    end

    def request_json(method, path, payload: nil, query: nil, timeout: WIREGUARD_API_TIMEOUT) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      response = @conn.public_send(method) do |req|
        req.url path
        req.params.update(query) if query
        req.options.timeout = timeout
        if payload
          req.headers['Content-Type'] = 'application/json'
          req.body = payload.to_json
        end
      end
      unless response.status.to_i.between?(200, 299)
        raise WireguardImportError, "opnsense returned HTTP #{response.status} for #{path}"
      end

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise WireguardImportError, "opnsense returned an invalid response for #{path}"
    end

    def expect_result(response, expected, action)
      return if response['result'] == expected

      validations = response.fetch('validations', {}).map { |field, message| "#{field}: #{Array(message).join(', ')}" }
      detail = validations.empty? ? response['result'].to_s : validations.join('; ')
      raise WireguardImportError, "opnsense could not #{action}#{detail.empty? ? '' : ": #{detail}"}"
    end

    def faraday_conn(config)
      Faraday.new(
        url: config[:opnsense_interface_addr],
        ssl: { verify: config[:opnsense_ssl_verify] },
        request: REQUEST_TIMEOUT
      ) do |faraday|
        faraday.request :authorization, :basic, config[:opnsense_api_key], config[:opnsense_api_secret]
      end
    end
  end
end
