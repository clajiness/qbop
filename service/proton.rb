module Service
  # The Proton class provides methods to interact with NAT-PMP (Network Address Translation Port Mapping Protocol)
  # using the `natpmpc` command-line tool.
  class Proton
    def initialize(helpers)
      @helpers = helpers
    end

    def natpmpc(proton_gateway)
      loop_freq = @helpers.env_variables[:loop_freq]
      timeout = (loop_freq - 5) >= 5 ? loop_freq - 5 : 5

      udp = natpmpc_command(timeout, 'udp', proton_gateway)
      tcp = udp[:status].success? ? natpmpc_command(timeout, 'tcp', proton_gateway) : empty_result

      combine_results(udp, tcp)
    end

    def parse_response(proton_response)
      return unless !proton_response.nil? && proton_response.include?('Mapped public port')

      marker_string0 = 'port '
      marker_string1 = ' protocol'

      proton_response[/#{marker_string0}(.*?)#{marker_string1}/m, 1].to_i
    end

    private

    def natpmpc_command(timeout, protocol, proton_gateway)
      stdout, stderr, status = Open3.capture3(
        'timeout', timeout.to_s, 'natpmpc', '-a', '1', '0', protocol, '60', '-g', proton_gateway.to_s
      )

      { stdout: stdout, stderr: stderr, status: status }
    end

    def empty_result
      { stdout: '', stderr: '', status: nil }
    end

    def combine_results(udp, tcp)
      {
        stdout: udp[:stdout] + tcp[:stdout],
        stderr: udp[:stderr] + tcp[:stderr],
        status: tcp[:status] || udp[:status]
      }
    end
  end
end
