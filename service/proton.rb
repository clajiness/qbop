module Service
  # The Proton class provides methods to interact with NAT-PMP (Network Address Translation Port Mapping Protocol)
  # using the `natpmpc` command-line tool.
  class Proton
    def proton_natpmpc(proton_gateway)
      stdout, stderr, status = Open3.capture3(
        "timeout 5 natpmpc -a 1 0 udp 60 -g #{proton_gateway} && natpmpc -a 1 0 tcp 60 -g #{proton_gateway}"
      )

      { stdout: stdout, stderr: stderr, status: status }
    end

    def parse_proton_response(proton_response)
      return unless !proton_response.nil? && proton_response.include?('Mapped public port')

      marker_string0 = 'port '
      marker_string1 = ' protocol'

      proton_response[/#{marker_string0}(.*?)#{marker_string1}/m, 1].to_i
    end
  end
end
