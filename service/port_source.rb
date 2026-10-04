require_relative 'proton'

module Service
  # Port sources expose current_port, returning an Integer or nil when unavailable.
  # Acquisition errors propagate to the job's existing logging and recovery logic.
  module PortSource
    def self.build(helpers, config)
      Proton.new(helpers, gateway: config[:proton_gateway])
    end
  end
end
