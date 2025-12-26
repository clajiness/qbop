require 'bundler/setup'
Bundler.require(:default)

require_relative '../../service/helpers'

RSpec.describe Service::Helpers do # rubocop:disable Metrics/BlockLength
  describe '#env_variables' do # rubocop:disable Metrics/BlockLength
    context 'when ui_mode is not set' do
      it 'returns dark' do
        expect(Service::Helpers.new.env_variables[:ui_mode]).to eq('dark')
      end
      it 'does not return nil' do
        expect(Service::Helpers.new.env_variables[:ui_mode]).not_to eq('nil')
      end
    end
    context 'when script_version is not set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:script_version]).to eq(nil)
      end
    end
    context 'when loop_freq is not set' do
      it 'returns the loop frequency' do
        expect(Service::Helpers.new.env_variables[:loop_freq]).to eq(45)
      end
      it 'does not return nil' do
        expect(Service::Helpers.new.env_variables[:loop_freq]).not_to eq(nil)
      end
    end
    context 'when required_attempts is not set' do
      it 'returns the required attempts' do
        expect(Service::Helpers.new.env_variables[:required_attempts]).to eq(3)
      end
      it 'does not return nil' do
        expect(Service::Helpers.new.env_variables[:required_attempts]).not_to eq(nil)
      end
    end
    context 'when proton_gateway is not set' do
      it 'returns the proton gateway' do
        expect(Service::Helpers.new.env_variables[:proton_gateway]).to eq('10.2.0.1')
      end
      it 'does not return nil' do
        expect(Service::Helpers.new.env_variables[:proton_gateway]).not_to eq(nil)
      end
    end
    context 'when opnsense_skip is not set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:opnsense_skip]).to eq('false')
      end
    end
    context 'when opnsense_interface_addr is not set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:opnsense_interface_addr]).to eq(nil)
      end
    end
    context 'when opnsense_api_key is not set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:opnsense_api_key]).to eq(nil)
      end
    end
    context 'when opnsense_api_secret is not set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:opnsense_api_secret]).to eq(nil)
      end
    end
    context 'when opnsense_alias_name is not set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:opnsense_alias_name]).to eq(nil)
      end
    end
    context 'when qbit_skip is not set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:qbit_skip]).to eq('false')
      end
    end
    context 'when qbit_addr is not set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:qbit_addr]).to eq(nil)
      end
    end
    context 'when qbit_user is not set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:qbit_user]).to eq(nil)
      end
    end
    context 'when qbit_pass is not set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:qbit_pass]).to eq(nil)
      end
    end
    context 'when log_lines is not set' do
      it 'returns the log lines' do
        expect(Service::Helpers.new.env_variables[:log_lines]).to eq(50)
      end
      it 'does not return nil' do
        expect(Service::Helpers.new.env_variables[:log_lines]).not_to eq(nil)
      end
    end
    context 'when log_reverse is not set' do
      it 'returns the log reverse' do
        expect(Service::Helpers.new.env_variables[:log_reverse]).to eq('false')
      end
      it 'does not return nil' do
        expect(Service::Helpers.new.env_variables[:log_reverse]).not_to eq(nil)
      end
    end
    context 'when log_to_stdout is not set' do
      it 'returns the log to stdout' do
        expect(Service::Helpers.new.env_variables[:log_to_stdout]).to eq('false')
      end
      it 'does not return nil' do
        expect(Service::Helpers.new.env_variables[:log_to_stdout]).not_to eq(nil)
      end
    end
    context 'when basic_auth_enabled is not set' do
      it 'returns basic_auth_enabled as false' do
        expect(Service::Helpers.new.env_variables[:basic_auth_enabled]).to eq('false')
      end
    end
    context 'when basic_auth_user is not set' do
      it 'returns basic_auth_user as admin' do
        expect(Service::Helpers.new.env_variables[:basic_auth_user]).to eq('admin')
      end
    end
    context 'when basic_auth_pass is not set' do
      it 'returns basic_auth_pass as admin' do
        expect(Service::Helpers.new.env_variables[:basic_auth_pass]).to eq('admin')
      end
    end
  end

  describe '#format_ui_mode' do
    it 'returns the ui_mode when properly formatted' do
      expect(Service::Helpers.new.format_ui_mode('light')).to eq('light')
    end
    it 'returns the capitalized ui_mode in lowercase string' do
      expect(Service::Helpers.new.format_ui_mode('DaRk')).to eq('dark')
    end
    it 'returns nil when ui_mode is nil' do
      expect(Service::Helpers.new.format_ui_mode(nil)).to eq(nil)
    end
  end

  describe '#validate_loop_frequency' do
    it 'returns the argument if it is a positive integer' do
      expect(Service::Helpers.new.validate_loop_frequency(45)).to eq(45)
    end
    it 'returns the positive argument if it is a negative integer' do
      expect(Service::Helpers.new.validate_loop_frequency(-45)).to eq(45)
    end
    it 'returns 45 if the argument is 0' do
      expect(Service::Helpers.new.validate_loop_frequency(0)).to eq(45)
    end
    it 'returns 45 if the argument is nil' do
      expect(Service::Helpers.new.validate_loop_frequency(nil)).to eq(45)
    end
  end

  describe '#validate_required_attempts' do
    it 'returns the argument if it is between 1 and 10' do
      expect(Service::Helpers.new.validate_required_attempts(5)).to eq(5)
    end
    it 'returns 3 if the argument is less than 1' do
      expect(Service::Helpers.new.validate_required_attempts(0)).to eq(3)
    end
    it 'returns 3 if the argument is greater than 10' do
      expect(Service::Helpers.new.validate_required_attempts(11)).to eq(3)
    end
    it 'returns 3 if the argument is nil' do
      expect(Service::Helpers.new.validate_required_attempts(nil)).to eq(3)
    end
  end

  describe '#true?' do
    it 'returns true for "true" string' do
      expect(Service::Helpers.new.true?('true')).to eq(true)
    end
    it 'returns true for capitalized "TRUE" string' do
      expect(Service::Helpers.new.true?('TRUE')).to eq(true)
    end
    it 'returns false for "false" string' do
      expect(Service::Helpers.new.true?('false')).to eq(false)
    end
    it 'returns false for nil' do
      expect(Service::Helpers.new.true?(nil)).to eq(false)
    end
  end

  describe '#get_db_version' do
    it 'returns unknown when database is not set up' do
      expect(Service::Helpers.new.get_db_version).to eq('unknown')
    end
  end

  describe '#time_delta' do
    it 'returns the time delta in seconds' do
      expect(Service::Helpers.new.time_delta('2024-01-02 12:00:00', '2024-01-02 11:59:00')).to eq(60)
    end
    it 'returns unknown for invalid time' do
      expect(Service::Helpers.new.time_delta('invalid', '2024-01-02 11:59:00')).to eq('unknown')
    end
  end

  describe '#time_delta_to_s' do
    it 'returns the time delta as a formatted string' do
      expect(Service::Helpers.new.time_delta_to_s('2024-01-03 13:01:05', '2024-01-01 12:00:00')).to eq('2d, 1h, 1m, 5s')
    end
    it 'returns unknown for invalid time' do
      expect(Service::Helpers.new.time_delta_to_s('invalid', '2024-01-02 11:59:00')).to eq('unknown')
    end
  end

  describe '#seconds_to_s' do
    it 'returns the seconds as a formatted string' do
      expect(Service::Helpers.new.seconds_to_s(90_061)).to eq('1d, 1h, 1m, 1s')
    end
    it 'returns 0 for invalid seconds string' do
      expect(Service::Helpers.new.seconds_to_s('invalid')).to eq('0d, 0h, 0m, 0s')
    end
    it 'returns "unknown" for boolean false' do
      expect(Service::Helpers.new.seconds_to_s(false)).to eq('unknown')
    end
  end

  describe '#connected_to_service?' do
    it 'returns true for recent last_checked time' do
      expect(Service::Helpers.new.connected_to_service?((Time.now - 60).to_s)).to eq(true)
    end
    it 'returns false for old last_checked time' do
      expect(Service::Helpers.new.connected_to_service?((Time.now - 10_000).to_s)).to eq(false)
    end
    it 'returns false for invalid time' do
      expect(Service::Helpers.new.connected_to_service?('invalid')).to eq(false)
    end
  end

  describe '#update_available?' do
    it 'returns true or false' do
      result = Service::Helpers.new.update_available?
      expect([true, false]).to include(result)
    end
  end

  describe 'log_lines_to_a' do
    it 'returns an empty array for nil input' do
      expect(Service::Helpers.new.log_lines_to_a(nil)).to eq([])
    end
  end

  describe '#gemfile_to_a' do
    it 'returns an array of gem names' do
      gem_names = Service::Helpers.new.gemfile_to_a
      expect(gem_names.first.include?('source')).to eq(true)
    end
  end

  describe '#generate_wg_public_key' do
    it 'returns error for invalid private key' do
      expect(Service::Helpers.new.generate_wg_public_key('invalid_key')).to eq('wg: Key is not the correct length or format') # rubocop:disable Layout/LineLength
    end
  end

  describe '#get_public_ip' do
    it 'returns unknown provider when given an invalid argument' do
      expect(Service::Helpers.new.get_public_ip('invalid_argument')).to eq('unknown service')
    end
  end

  describe '#logger_instance' do
    require 'logger'
    it 'returns a logger instance' do
      default = Logger.new('log/qbop.log', 10, 5_120_000)
      expect(Service::Helpers.new.logger_instance.class).to eq(default.class)
    end
  end
end
