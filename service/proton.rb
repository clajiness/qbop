module Service
  # The Proton class provides methods to interact with NAT-PMP (Network Address Translation Port Mapping Protocol)
  # using the `natpmpc` command-line tool.
  class Proton
    class MappingError < StandardError; end

    def initialize(helpers, gateway: helpers.env_variables[:proton_gateway])
      @helpers = helpers
      @gateway = gateway
    end

    def current_port
      forwarded_port(natpmpc(@gateway))
    end

    def name
      'proton'
    end

    def natpmpc(proton_gateway)
      loop_freq = @helpers.env_variables[:loop_freq]
      timeout = (loop_freq - 5) >= 5 ? loop_freq - 5 : 5

      udp = natpmpc_command(timeout, 'udp', proton_gateway)
      tcp = udp[:status].success? ? natpmpc_command(timeout, 'tcp', proton_gateway) : empty_result

      { udp: udp, tcp: tcp }
    end

    def forwarded_port(response)
      udp_port = mapped_port(response.fetch(:udp), 'UDP')
      tcp_port = mapped_port(response.fetch(:tcp), 'TCP')
      return udp_port if udp_port == tcp_port

      raise MappingError, "UDP and TCP NAT-PMP ports do not match (#{udp_port} and #{tcp_port})"
    end

    def parse_response(proton_response, protocol = nil)
      protocol_pattern = protocol ? Regexp.escape(protocol) : '[A-Za-z]+'
      port = proton_response.to_s[/Mapped public port\s+(\d+)\s+protocol\s+#{protocol_pattern}\b/i, 1]
      port&.to_i
    end

    private

    def mapped_port(result, protocol)
      validate_command_result(result, protocol)

      port = parse_response(result[:stdout], protocol)
      return port if port&.between?(1024, 65_535)

      raise MappingError, "#{protocol} NAT-PMP response did not contain a valid mapped port"
    end

    def validate_command_result(result, protocol)
      detail = result[:stderr].to_s.strip
      unless result[:status]&.success?
        raise MappingError, "#{protocol} NAT-PMP command failed#{": #{detail}" unless detail.empty?}"
      end
      return if detail.empty?

      raise MappingError, "#{protocol} NAT-PMP command reported an error: #{detail}"
    end

    def natpmpc_command(timeout, protocol, proton_gateway)
      stdout, stderr, status = Open3.capture3(
        'timeout', timeout.to_s, 'natpmpc', '-a', '1', '0', protocol, '60', '-g', proton_gateway.to_s
      )

      { stdout: stdout, stderr: stderr, status: status }
    end

    def empty_result
      { stdout: '', stderr: '', status: nil }
    end
  end
end
