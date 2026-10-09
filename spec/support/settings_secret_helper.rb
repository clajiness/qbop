require 'tmpdir'
require_relative '../../service/settings'

module SpecSettingsSecrets
  # Expected legacy no-DB blank behavior, independent of the production registry.
  CREDENTIALS = {
    gluetun_api_key: ['GLUETUN_API_KEY', false], gluetun_user: ['GLUETUN_USER', false],
    gluetun_pass: ['GLUETUN_PASS', false], opnsense_api_key: ['OPN_API_KEY', true],
    opnsense_api_secret: ['OPN_API_SECRET', true], qbit_api_key: ['QBIT_API_KEY', false],
    qbit_user: ['QBIT_USER', true], qbit_pass: ['QBIT_PASS', true]
  }.freeze
  ENV_NAMES = (CREDENTIALS.values.map(&:first) + %w[
    LOOP_FREQ REQUIRED_ATTEMPTS PORT_SOURCE PROTON_GATEWAY UI_MODE LOG_LINES LOG_REVERSE LOG_TO_STDOUT
    GLUETUN_ADDR GLUETUN_SSL_VERIFY OPN_SKIP OPN_INTERFACE_ADDR OPN_ALIAS_NAME OPN_PROTON_ALIAS_NAME
    OPN_SSL_VERIFY QBIT_SKIP QBIT_ADDR QBIT_SSL_VERIFY
  ]).freeze
end

RSpec.shared_context 'encrypted settings' do
  let(:key_path) { @settings_key_path }
  let(:settings) { Service::Settings.new(encryption_key_path: key_path) }

  before { stub_const('Service::SettingsEncryptionKey::DEFAULT_PATH', key_path) }

  around do |example|
    original = SpecSettingsSecrets::ENV_NAMES.to_h { |name| [name, ENV[name]] }
    original.each_key { |name| ENV.delete(name) }
    Dir.mktmpdir('qbop-settings') do |directory|
      @settings_key_path = File.join(directory, 'settings_encryption_key.txt')
      example.run
    end
  ensure
    original.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end
end
