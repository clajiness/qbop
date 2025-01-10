module Service
  # tracks the number of attempts to change the port in opnsense and qBit
  class Counter
    attr_reader :required_attempts, :opnsense_attempt, :opnsense_change, :qbit_attempt, :qbit_change

    def initialize
      @required_attempts = 3
      @opnsense_attempt = 0
      @opnsense_change = false
      @qbit_attempt = 0
      @qbit_change = false
    end

    def set_required_attempts(attempts)
      attempts = attempts&.to_i

      if !attempts&.nil? && attempts&.between?(1, 10)
        @required_attempts = attempts
      else
        @required_attempts
      end
    end

    def increment_opnsense_attempt
      @opnsense_attempt += 1
    end

    def increment_qbit_attempt
      @qbit_attempt += 1
    end

    def reset_opnsense_attempt
      @opnsense_attempt = 0
    end

    def reset_qbit_attempt
      @qbit_attempt = 0
    end

    def change_opnsense
      @opnsense_change = true
    end

    def change_qbit
      @qbit_change = true
    end

    def reset_opnsense_change
      @opnsense_change = false
    end

    def reset_qbit_change
      @qbit_change = false
    end
  end
end
