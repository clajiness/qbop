require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'
require_relative '../../service/settings'
require_relative '../../service/helpers'

RSpec.describe 'Additional settings resolution' do # rubocop:disable Metrics/BlockLength
  let(:environment) { {} }
  let(:settings) { Service::Settings.new(environment: environment) }

  before { SpecDatabase.reset! }

  # rubocop:disable Metrics/BlockLength
  {
    ui_mode: ['UI_MODE', 'dark', 'light', 'light', true],
    log_lines: ['LOG_LINES', 50, '75', '75', true],
    log_reverse: ['LOG_REVERSE', 'false', 'true', 'true', true],
    log_to_stdout: ['LOG_TO_STDOUT', 'false', 'true', 'true', true],
    gluetun_addr: ['GLUETUN_ADDR', 'http://gluetun:8000', 'https://gluetun/control', 'https://gluetun/control', false],
    gluetun_ssl_verify: ['GLUETUN_SSL_VERIFY', false, 'true', true, false],
    opnsense_skip: ['OPN_SKIP', 'false', 'true', 'true', true],
    opnsense_interface_addr: ['OPN_INTERFACE_ADDR', nil, 'https://firewall/', 'https://firewall/', true],
    opnsense_alias_name: ['OPN_ALIAS_NAME', nil, 'stored_alias', 'stored_alias', false],
    opnsense_ssl_verify: ['OPN_SSL_VERIFY', false, 'true', true, false],
    qbit_skip: ['QBIT_SKIP', 'false', 'true', 'true', true],
    qbit_addr: ['QBIT_ADDR', nil, 'http://qbit:8080/', 'http://qbit:8080/', true],
    qbit_ssl_verify: ['QBIT_SSL_VERIFY', false, 'true', true, false]
  }.each do |key, (environment_name, default, input, resolved, preserve_blank)|
    it "resolves #{key} defaults without creating rows and preserves legacy blank behavior" do
      expect(settings.resolve(key).to_h).to eq(
        value: default, source: :default, environment_name: nil, environment_override: false
      )
      expect(settings.resolve(key).environment_override?).to be(false)
      ['', " \t\n"].each do |blank|
        environment[environment_name] = blank
        result = Service::Settings.new(environment: environment).resolve(key)
        expect(result.value).to eq(preserve_blank ? blank : default)
        expect(result.source).to eq(preserve_blank ? :environment : :default)
        expect(result.environment_name).to eq(preserve_blank ? environment_name : nil)
        expect(result.environment_override?).to be(false)
      end
      expect(Setting.count).to eq(0)
    end

    it "uses stored #{key}, permits blank ENV overrides, and gives meaningful ENV precedence" do
      settings.set(key, input)
      expect(settings.resolve(key).to_h).to eq(
        value: resolved, source: :database, environment_name: nil, environment_override: false
      )
      ['', " \t\n"].each do |blank|
        environment[environment_name] = blank
        expect(Service::Settings.new(environment: environment).resolve(key).to_h)
          .to eq(value: resolved, source: :database, environment_name: nil, environment_override: false)
      end
      environment[environment_name] = input
      expect(Service::Settings.new(environment: environment).resolve(key).to_h)
        .to eq(value: resolved, source: :environment, environment_name: environment_name, environment_override: true)
      expect(Service::Settings.new(environment: environment).resolve(key).environment_override?).to be(true)
      expect(Setting.count).to eq(1)
    end
  end
  # rubocop:enable Metrics/BlockLength

  describe 'effective OPNsense alias' do # rubocop:disable Metrics/BlockLength
    before { settings.set(:opnsense_alias_name, 'stored_alias') }

    it 'prefers OPN_ALIAS_NAME ahead of legacy ENV and the single DB setting' do
      environment.update('OPN_ALIAS_NAME' => 'preferred_alias', 'OPN_PROTON_ALIAS_NAME' => 'legacy_alias')

      expect(Service::Settings.new(environment: environment).resolve(:opnsense_alias_name).to_h).to eq(
        value: 'preferred_alias', source: :environment, environment_name: 'OPN_ALIAS_NAME', environment_override: true
      )
      expect(Setting.select_map(:name)).to eq(['opnsense_alias_name'])
    end

    [nil, '', ' '].each do |preferred|
      it "uses legacy ENV ahead of DB when preferred ENV is #{preferred.inspect}" do
        environment['OPN_ALIAS_NAME'] = preferred unless preferred.nil?
        environment['OPN_PROTON_ALIAS_NAME'] = ' legacy_alias '

        expect(Service::Settings.new(environment: environment).resolve(:opnsense_alias_name).to_h).to eq(
          value: ' legacy_alias ', source: :environment, environment_name: 'OPN_PROTON_ALIAS_NAME',
          environment_override: true
        )
      end
    end

    it 'uses DB when both environment variables are blank and restores unset behavior on delete' do
      environment.update('OPN_ALIAS_NAME' => ' ', 'OPN_PROTON_ALIAS_NAME' => '')

      expect(settings.resolve(:opnsense_alias_name).source).to eq(:database)
      expect(settings.resolve(:opnsense_alias_name).environment_override?).to be(false)
      expect(settings.delete(:opnsense_alias_name).to_h).to eq(
        value: nil, source: :default, environment_name: nil, environment_override: false
      )
    end
  end

  it 'preserves permissive UI and boolean ENV parsing while keeping ENV authoritative' do
    settings.set(:ui_mode, 'light')
    environment['UI_MODE'] = 'SePiA'
    expect(Service::Settings.new(environment: environment).value(:ui_mode)).to eq('sepia')
    helpers = Service::Helpers.new
    { log_reverse: 'LOG_REVERSE', log_to_stdout: 'LOG_TO_STDOUT', gluetun_ssl_verify: 'GLUETUN_SSL_VERIFY',
      opnsense_skip: 'OPN_SKIP', opnsense_ssl_verify: 'OPN_SSL_VERIFY', qbit_skip: 'QBIT_SKIP',
      qbit_ssl_verify: 'QBIT_SSL_VERIFY' }.each do |key, environment_name|
      settings.set(key, true)
      ['true', 'TRUE', ' true ', 'false', 'yes', '1'].each do |input|
        environment[environment_name] = input
        result = Service::Settings.new(environment: environment).resolve(key)
        expect(helpers.true?(result.value)).to eq(helpers.true?(input))
        expect(result.source).to eq(:environment)
        expect(result.environment_name).to eq(environment_name)
        expect(result.environment_override?).to be(true)
      end
    end
  end

  it 'does not retroactively validate manually inserted UI, boolean, or URL values' do
    { ui_mode: 'SePiA', gluetun_ssl_verify: 'yes', qbit_addr: 'unusual-manual-address' }
      .each { |key, value| Setting.create(name: key.to_s, value: value) }

    expect(settings.value(:ui_mode)).to eq('sepia')
    expect(settings.value(:gluetun_ssl_verify)).to be(false)
    expect(settings.value(:qbit_addr)).to eq('unusual-manual-address')
  end

  it 'keeps legacy ENV and manually stored integration path prefixes readable' do
    { opnsense_interface_addr: ['OPN_INTERFACE_ADDR', 'https://firewall/proxy'],
      qbit_addr: ['QBIT_ADDR', 'http://qbit:8080/qbit/'] }.each do |key, (environment_name, address)|
      environment[environment_name] = address
      result = Service::Settings.new(environment: environment).resolve(key)
      expect(result.value).to eq(address)
      expect(result.environment_override?).to be(true)
      environment.delete(environment_name)
      Setting.create(name: key.to_s, value: address)
      result = Service::Settings.new(environment: environment).resolve(key)
      expect(result.value).to eq(address)
      expect(result.environment_override?).to be(false)
    end
  end
end
