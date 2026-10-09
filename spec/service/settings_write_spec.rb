require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'
require_relative '../../service/settings'

RSpec.describe 'Settings writes' do # rubocop:disable Metrics/BlockLength
  let(:environment) { {} }
  let(:settings) { Service::Settings.new(environment: environment) }
  let(:error_class) { Service::Settings::ValidationError }

  before { SpecDatabase.reset! }

  {
    loop_freq: [' +0030 ', '30'], required_attempts: [5, '5'],
    port_source: [' gluetun ', 'gluetun'], proton_gateway: [' gateway.local ', 'gateway.local'],
    ui_mode: [' LIGHT ', 'light'], log_lines: [' 00500 ', '500'],
    log_reverse: [true, 'true'], log_to_stdout: [' FALSE ', 'false'],
    gluetun_addr: [' https://gluetun:8000/control/ ', 'https://gluetun:8000/control/'],
    gluetun_ssl_verify: [false, 'false'], opnsense_skip: [' TRUE ', 'true'],
    opnsense_interface_addr: [' https://firewall.local:8443/ ', 'https://firewall.local:8443/'],
    opnsense_alias_name: [' forwarded port ', 'forwarded port'], opnsense_ssl_verify: %w[TrUe true],
    qbit_skip: [false, 'false'], qbit_addr: [' http://qbit:8080 ', 'http://qbit:8080'],
    qbit_ssl_verify: %w[FaLsE false]
  }.each do |key, (input, canonical)|
    it "persists #{key} canonically and updates the existing row on repeated writes" do
      settings.resolve(key)
      result = settings.set(key, input)
      original_id = Setting[name: key.to_s].id
      settings.set(key, canonical)

      expect(Setting.select_map(%i[name value])).to eq([[key.to_s, canonical]])
      expect(Setting[name: key.to_s].id).to eq(original_id)
      expect(result.source).to eq(:database)
      expect(result.environment_name).to be_nil
      expect(result.environment_override?).to be(false)
    end
  end

  { loop_freq: [1, 120], required_attempts: [1, 10], log_lines: [1, 5000] }.each do |key, valid_values|
    it "accepts the valid numeric boundaries for #{key}" do
      valid_values.each do |value|
        settings.set(key, value)
        expect(Setting[name: key.to_s].value).to eq(value.to_s)
      end
    end
  end

  {
    loop_freq: [nil, '', ' ', '30abc', '1.5', 1.5, '1_000', '0x20', '1e2', 0, -1],
    required_attempts: ['5abc', '1.5', 5.0, 0, 11],
    log_lines: ['50abc', '1.5', 50.0, 0, 5001],
    port_source: ['', 'unsupported', 'GLUETUN'], ui_mode: ['', 'system'],
    proton_gateway: [nil, ' ', 123], opnsense_alias_name: [nil, ' ', 123]
  }.each do |key, invalid_values|
    it "rejects invalid #{key} writes without creating or changing rows or cached resolution" do
      original = settings.resolve(key)
      invalid_values.each do |value|
        expect { settings.set(key, value) }.to raise_error(error_class)
        expect(Setting.count).to eq(0)
        expect(settings.resolve(key)).to equal(original)
      end
      Setting.create(name: key.to_s, value: 'legacy-value')
      invalid_values.each do |value|
        expect { settings.set(key, value) }.to raise_error(error_class)
        expect(Setting[name: key.to_s].value).to eq('legacy-value')
      end
    end
  end

  %i[log_reverse log_to_stdout gluetun_ssl_verify opnsense_skip opnsense_ssl_verify qbit_skip qbit_ssl_verify]
    .each do |key|
      it "accepts only unambiguous true/false writes for #{key}" do
        { true => 'true', false => 'false', ' TRUE ' => 'true', 'FaLsE' => 'false' }.each do |input, expected|
          settings.set(key, input)
          expect(Setting[name: key.to_s].value).to eq(expected)
        end
        ['yes', '1', 1, 'enabled', 'random', nil, ''].each do |input|
          expect { settings.set(key, input) }.to raise_error(error_class, /must be true or false/)
          expect(Setting[name: key.to_s].value).to eq('false')
        end
      end
    end

  %i[gluetun_addr opnsense_interface_addr qbit_addr].each do |key| # rubocop:disable Metrics/BlockLength
    it "accepts HTTP(S) origins, explicit ports, and root trailing slashes for #{key}" do
      %w[http://service https://service http://service:1/ https://service:65535/].each do |address|
        settings.set(key, address)
        expect(Setting[name: key.to_s].value).to eq(address)
      end
    end

    it "rejects invalid #{key} endpoints without leaking submitted material or changing storage" do
      settings.set(key, 'https://service/')
      ['', ' ', 'ftp://service', 'http:/service', 'https:///path',
       'http://service:0', 'http://service:65536', 'http://service:invalid', 'http://service:',
       'http://user-secret:pass-secret@service:8000', 'http://@service',
       'http://user-secret:pass secret@service',
       'http://service/path?token=query-secret', 'http://service/path#fragment-secret',
       'http://service?', 'http://service#'].each do |address|
        expect { settings.set(key, address) }.to raise_error(error_class) { |error|
          expect(error.message).to include('HTTP(S)', 'without userinfo, query, or fragment')
          expect(error.full_message).not_to include(
            'user-secret', 'pass-secret', 'pass secret', 'query-secret', 'fragment-secret'
          )
          expect(error.cause).to be_nil
        }
        expect(Setting[name: key.to_s].value).to eq('https://service/')
      end
    end

    it "does not create #{key} when URL validation fails" do
      expect { settings.set(key, 'http://user-secret:pass-secret@service') }.to raise_error(error_class)
      expect(Setting.count).to eq(0)
    end
  end

  it 'continues accepting Gluetun reverse-proxy path prefixes' do
    %w[http://gluetun:8000/control https://gluetun.example/proxy/control/].each do |address|
      settings.set(:gluetun_addr, address)
      expect(Setting[name: 'gluetun_addr'].value).to eq(address)
    end
  end

  %i[opnsense_interface_addr qbit_addr].each do |key|
    it "rejects non-root #{key} paths without creating or updating an override" do
      %w[https://service/proxy https://service/qbit/ https://service/submitted-private-path].each do |address|
        expect { settings.set(key, address) }.to raise_error(error_class) { |error|
          expect(error.message).to include('origin/root URL')
          expect(error.full_message).not_to include(address, 'submitted-private-path')
          expect(error.cause).to be_nil
        }
        expect(Setting.count).to eq(0)
      end
      settings.set(key, 'https://service/')
      expect { settings.set(key, 'https://service/proxy') }.to raise_error(error_class)
      expect(Setting[name: key.to_s].value).to eq('https://service/')
    end
  end

  it 'identifies numeric validation requirements without echoing submitted values' do
    expect { settings.set(:required_attempts, 'submitted-secret') }
      .to raise_error(error_class, 'REQUIRED_ATTEMPTS must be a complete integer in 1..10.')
    expect { settings.set(:loop_freq, 'submitted-secret') }
      .to raise_error(error_class, 'LOOP_FREQ must be a complete integer greater than 0.')
    expect { settings.set(:log_lines, 'submitted-secret') }
      .to raise_error(error_class, 'LOG_LINES must be a complete integer in 1..5000.')
  end

  it 'rejects unknown, legacy alias, browser authentication and metadata keys' do
    %i[unknown opn_proton_alias_name web_auth_enabled local_login_enabled
       oidc_enabled oidc_issuer oidc_client_id oidc_client_secret oidc_public_url oidc_auto_redirect
       version commit_sha build_date].each do |key|
      expect { settings.set(key, 'submitted-secret') }.to raise_error(error_class, 'Unsupported setting key.')
      expect { settings.delete(key) }.to raise_error(error_class, 'Unsupported setting key.')
    end
    expect { settings.set('http://user-secret:pass-secret@service', 'value') }
      .to raise_error(error_class, 'Unsupported setting key.')
    expect(Setting.count).to eq(0)
  end

  it 'clears only the requested override and immediately restores fallback in the calling resolver' do
    settings.set(:loop_freq, 60)
    settings.set(:required_attempts, 7)

    expect(settings.delete(:loop_freq).to_h).to eq(
      value: 45, source: :default, environment_name: nil, environment_override: false
    )
    expect(Setting.select_map(%i[name value])).to eq([%w[required_attempts 7]])
    expect(settings.value(:required_attempts)).to eq(7)
    expect(settings.delete(:loop_freq).value).to eq(45)
  end

  it 'respects environment precedence on writes and deletes without altering the environment' do
    environment['LOOP_FREQ'] = '30'
    original_environment = environment.dup

    expect(settings.set(:loop_freq, 60).to_h).to eq(
      value: 30, source: :environment, environment_name: 'LOOP_FREQ', environment_override: true
    )
    expect(Setting[name: 'loop_freq'].value).to eq('60')
    expect(settings.delete(:loop_freq).value).to eq(30)
    expect(environment).to eq(original_environment)
    expect(Setting.count).to eq(0)
  end

  it 'does not alter the process environment on set or delete' do
    original = ENV['LOOP_FREQ']
    ENV['LOOP_FREQ'] = '30'
    resolver = Service::Settings.new

    resolver.set(:loop_freq, 60)
    expect(ENV['LOOP_FREQ']).to eq('30')
    resolver.delete(:loop_freq)
    expect(ENV['LOOP_FREQ']).to eq('30')
  ensure
    original.nil? ? ENV.delete('LOOP_FREQ') : ENV['LOOP_FREQ'] = original
  end

  it 'leaves existing resolvers intact after another resolver writes or clears an override' do
    settings.set(:loop_freq, 60)
    snapshot = Service::Settings.new(environment: environment)
    expect(snapshot.value(:loop_freq)).to eq(60)

    expect(settings.set(:loop_freq, 120).value).to eq(120)
    expect(snapshot.value(:loop_freq)).to eq(60)
    expect(settings.delete(:loop_freq).value).to eq(45)
    expect(snapshot.value(:loop_freq)).to eq(60)
  end

  it 'preserves permissive ENV and manual database reads while rejecting partial integer writes' do
    environment['REQUIRED_ATTEMPTS'] = '5abc'
    expect(settings.value(:required_attempts)).to eq(5)
    expect { settings.set(:required_attempts, '5abc') }.to raise_error(error_class)
    environment.clear
    Setting.create(name: 'required_attempts', value: '5abc')

    expect(Service::Settings.new(environment: environment).value(:required_attempts)).to eq(5)
    expect { settings.set(:required_attempts, '5abc') }.to raise_error(error_class)
    expect(Setting[name: 'required_attempts'].value).to eq('5abc')
  end
end
