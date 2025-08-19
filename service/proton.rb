module Service
  # The Proton class provides methods to interact with NAT-PMP (Network Address Translation Port Mapping Protocol)
  # using the `natpmpc` command-line tool.
  class Proton
    def initialize(helpers)
      @helpers = helpers
    end

    def proton_natpmpc(proton_gateway)
      loop_freq = @helpers.env_variables[:loop_freq]
      timeout = (loop_freq - 5) >= 5 ? loop_freq - 5 : 5

      stdout, stderr, status = Open3.capture3(
        "timeout #{timeout} natpmpc -a 1 0 udp 60 -g #{proton_gateway} && natpmpc -a 1 0 tcp 60 -g #{proton_gateway}"
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
