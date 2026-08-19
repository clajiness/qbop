require 'io/console'

module Service
  # Resets the existing administrator password from an interactive terminal.
  class AccountRecovery
    class Error < StandardError; end

    def initialize(input: $stdin, output: $stdout, authentication: nil)
      @input = input
      @output = output
      @authentication = authentication || Framework::Authentication.rodauth
    end

    def reset_password
      account = DB[:accounts].first
      raise Error, 'no administrator account exists' unless account

      password, confirmation = read_passwords
      raise Error, 'password confirmation does not match' unless password && password == confirmation

      @authentication.change_password(account_id: account.fetch(:id), password: password)
      @output.puts 'password reset successfully'
    rescue Rodauth::InternalRequestError => e
      raise Error, e.message
    ensure
      clear_passwords(password, confirmation)
    end

    private

    def read_passwords
      [@input.getpass('new password: '), @input.getpass('confirm password: ')]
    end

    def clear_passwords(*passwords)
      passwords.compact.each(&:clear)
    end
  end
end
