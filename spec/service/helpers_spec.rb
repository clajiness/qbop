require 'bundler/setup'
Bundler.require(:default)

require_relative '../../service/helpers'

HELPERS_SPEC_ENV_KEYS = %w[
  UI_MODE
  VERSION
  COMMIT_SHA
  LOOP_FREQ
  REQUIRED_ATTEMPTS
  PROTON_GATEWAY
  OPN_SKIP
  OPN_INTERFACE_ADDR
  OPN_API_KEY
  OPN_API_SECRET
  OPN_PROTON_ALIAS_NAME
  OPN_SSL_VERIFY
  QBIT_SKIP
  QBIT_ADDR
  QBIT_API_KEY
  QBIT_USER
  QBIT_PASS
  QBIT_SSL_VERIFY
  LOG_LINES
  LOG_REVERSE
  LOG_TO_STDOUT
  BASIC_AUTH_ENABLED
  BASIC_AUTH_USER
  BASIC_AUTH_PASS
].freeze

RSpec.describe Service::Helpers do # rubocop:disable Metrics/BlockLength
  around do |example|
    original_env = HELPERS_SPEC_ENV_KEYS.to_h { |key| [key, ENV[key]] }
    HELPERS_SPEC_ENV_KEYS.each { |key| ENV.delete(key) }

    example.run
  ensure
    HELPERS_SPEC_ENV_KEYS.each { |key| original_env[key].nil? ? ENV.delete(key) : ENV[key] = original_env[key] }
  end

  describe '#env_variables' do # rubocop:disable Metrics/BlockLength
    context 'when ui_mode is not set' do
      it 'returns dark' do
        expect(Service::Helpers.new.env_variables[:ui_mode]).to eq('dark')
      end
      it 'does not return nil' do
        expect(Service::Helpers.new.env_variables[:ui_mode]).not_to eq(nil)
      end
    end
    context 'when script_version is not set' do
      it 'returns development' do
        expect(Service::Helpers.new.env_variables[:script_version]).to eq('development')
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
    context 'when opnsense_ssl_verify is not set' do
      it 'returns false' do
        expect(Service::Helpers.new.env_variables[:opnsense_ssl_verify]).to eq(false)
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
    context 'when qbit_api_key is not set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:qbit_api_key]).to eq(nil)
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
    context 'when qbit_ssl_verify is not set' do
      it 'returns false' do
        expect(Service::Helpers.new.env_variables[:qbit_ssl_verify]).to eq(false)
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

  describe 'build identity' do
    it 'returns development defaults' do
      helpers = Service::Helpers.new

      expect(helpers.app_version).to eq('development')
      expect(helpers.commit_sha).to eq('unknown')
      expect(helpers.short_commit_sha).to eq('unknown')
      expect(helpers.release_build?).to eq(false)
      expect(helpers.main_build?).to eq(false)
    end

    it 'identifies main builds and shortens their commit' do
      ENV['VERSION'] = 'main'
      ENV['COMMIT_SHA'] = '0123456789abcdef'
      helpers = Service::Helpers.new

      expect(helpers.main_build?).to eq(true)
      expect(helpers.release_build?).to eq(false)
      expect(helpers.short_commit_sha).to eq('0123456789ab')
    end

    it 'identifies stable release builds' do
      ENV['VERSION'] = 'v2.9.0'

      expect(Service::Helpers.new.release_build?).to eq(true)
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

  describe '#validate_refresh_interval' do
    it 'returns a positive refresh interval' do
      expect(Service::Helpers.new.validate_refresh_interval('5')).to eq(5)
    end

    it 'returns 0 when refresh is disabled' do
      expect(Service::Helpers.new.validate_refresh_interval('0')).to eq(0)
    end

    it 'clamps very large refresh intervals' do
      expect(Service::Helpers.new.validate_refresh_interval('9999')).to eq(3600)
    end
  end

  describe '#validate_log_lines' do
    it 'returns a positive line count' do
      expect(Service::Helpers.new.validate_log_lines('500')).to eq(500)
    end

    it 'returns the default for invalid line counts' do
      expect(Service::Helpers.new.validate_log_lines('invalid')).to eq(50)
    end

    it 'uses the configured default for invalid line counts' do
      ENV['LOG_LINES'] = '250'

      expect(Service::Helpers.new.validate_log_lines('invalid')).to eq(250)
    end

    it 'clamps very large line counts' do
      expect(Service::Helpers.new.validate_log_lines('9999')).to eq(5000)
    end
  end

  describe '#format_log_direction' do
    it 'returns desc for descending direction' do
      expect(Service::Helpers.new.format_log_direction('desc')).to eq('desc')
    end

    it 'returns asc by default' do
      expect(Service::Helpers.new.format_log_direction(nil)).to eq('asc')
    end

    it 'uses the reverse default when no direction is passed' do
      expect(Service::Helpers.new.format_log_direction(nil, default_reverse: true)).to eq('desc')
    end

    it 'uses the reverse default when an invalid direction is passed' do
      expect(Service::Helpers.new.format_log_direction('test', default_reverse: true)).to eq('desc')
    end
  end

  describe 'history pagination validation' do
    it 'accepts positive page numbers' do
      expect(Service::Helpers.new.validate_page('3')).to eq(3)
    end

    it 'defaults invalid page numbers to one' do
      expect(Service::Helpers.new.validate_page('-1')).to eq(1)
      expect(Service::Helpers.new.validate_page('invalid')).to eq(1)
    end

    it 'accepts supported page sizes' do
      expect(Service::Helpers.new.validate_history_page_size('50')).to eq(50)
    end

    it 'defaults unsupported page sizes to 25' do
      expect(Service::Helpers.new.validate_history_page_size('500')).to eq(25)
      expect(Service::Helpers.new.validate_history_page_size('invalid')).to eq(25)
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
    it 'returns true when the newest tag is newer than the app version' do
      ENV['VERSION'] = 'v2.6.0'

      expect(Service::Helpers.new.update_available?('v2.7.0')).to eq(true)
    end

    it 'returns false when the newest tag matches the app version' do
      ENV['VERSION'] = 'v2.7.0'

      expect(Service::Helpers.new.update_available?('v2.7.0')).to eq(false)
    end

    it 'returns false when the app version is missing' do
      expect(Service::Helpers.new.update_available?('v2.7.0')).to eq(false)
    end

    it 'returns false for main builds' do
      ENV['VERSION'] = 'main'

      expect(Service::Helpers.new.update_available?('v2.7.0')).to eq(false)
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
      allow(Open3).to receive(:capture3)
        .with('wg', 'pubkey', stdin_data: "invalid_key\n")
        .and_return(['', "wg: Key is not the correct length or format\n"])

      expect(Service::Helpers.new.generate_wg_public_key('invalid_key')).to eq('wg: Key is not the correct length or format') # rubocop:disable Layout/LineLength
    end
  end

  describe '#get_public_ip' do
    it 'returns unknown provider when given an invalid argument' do
      expect(Service::Helpers.new.get_public_ip('invalid_argument')).to eq('unknown provider')
    end

    it 'uses array command arguments for known providers' do
      allow(Open3).to receive(:capture3)
        .with('timeout', '5', 'dig', 'myip.opendns.com', '@dns.opendns.com', '+short')
        .and_return(["192.0.2.1\n", ''])

      expect(Service::Helpers.new.get_public_ip('opendns')).to eq("192.0.2.1\n")
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
