require 'bundler/setup'
Bundler.require(:default)
require 'active_support/json'
require 'pp'
require_relative '../support/database_helper'
require_relative '../support/settings_secret_helper'
require_relative '../../service/helpers'

RSpec.describe 'Encrypted settings storage and resolution' do # rubocop:disable Metrics/BlockLength
  include_context 'encrypted settings'

  before { SpecDatabase.reset! }

  def expect_safe_failure(&operation)
    expect(&operation).to raise_error(Service::Settings::ConfigurationError) do |error|
      expect(error.cause).to be_nil
      expect(error.full_message).not_to include('private-credential', 'private-key', 'enc:v1:')
    end
  end

  SpecSettingsSecrets::CREDENTIALS.each do |key, (environment_name, preserve_blank)| # rubocop:disable Metrics/BlockLength
    it "stores #{key} only as authenticated ciphertext, with exact plaintext accessible through value" do
      plaintext = "  #{key}-private-credential-秘密  "
      result = settings.set(key, plaintext)
      stored = Setting[name: key.to_s].value

      expect(stored).to start_with('enc:v1:')
      expect(stored).not_to include(plaintext, 'private-credential')
      expect(result.value).to eq(plaintext)
      expect(result.value).to be_frozen
      expect(result.source).to eq(:database)
      expect(result.environment_override?).to be(false)
      expect(result.secret?).to be(true)
      expect(result.environment_name).to be_nil
      expect(result.to_h).to include(value: '***', secret: true)
      [result.inspect, result.to_s, result.to_h.inspect, result.as_json.inspect, result.to_json,
       result.to_h { |name, value| [name.to_s, value] }.inspect, JSON.generate(result),
       PP.pp(result, +'')].each do |representation|
        expect(representation).not_to include('private-credential', stored)
      end
      expect(Service::Settings.new.value(key)).to eq(plaintext)
      expect(Service::Helpers.new.env_variables[key]).to eq(plaintext)
      expect(Setting.count).to eq(1)
    end

    it "keeps meaningful #{environment_name} authoritative without decrypting an overridden DB row" do
      settings.set(key, 'database-private-credential')
      File.unlink(key_path)
      Setting[name: key.to_s].update(value: 'malformed-private-credential')
      ENV[environment_name] = ' env-private-credential '
      expect(Service::SettingsEncryption).not_to receive(:new)
      expect(Setting).not_to receive(:[])

      result = Service::Settings.new.resolve(key)

      expect(result.value).to eq(' env-private-credential ')
      expect(result.source).to eq(:environment)
      expect(result.environment_name).to eq(environment_name)
      expect(result.environment_override?).to be(true)
      expect(result.secret?).to be(true)
      expect(result.inspect).not_to include('env-private-credential')
      expect(File.exist?(key_path)).to be(false)
    end

    it "lets encrypted #{key} participate under blank ENV placeholders" do
      settings.set(key, 'database-private-credential')
      ['', " \t\n"].each do |blank|
        ENV[environment_name] = blank
        result = Service::Settings.new.resolve(key)
        expect(result.value).to eq('database-private-credential')
        expect(result.source).to eq(:database)
        expect(result.environment_override?).to be(false)
        expect(result.environment_name).to be_nil
      end
      expect(Setting.count).to eq(1)
    end

    it "preserves absent and legacy blank #{environment_name} without importing or creating a key" do
      expect(settings.value(key)).to be_nil
      expect(settings.resolve(key).source).to eq(:default)
      ['', " \t\n"].each do |blank|
        ENV[environment_name] = blank
        result = Service::Settings.new.resolve(key)
        expect(result.value).to eq(preserve_blank ? blank : nil)
        expect(result.source).to eq(preserve_blank ? :environment : :default)
        expect(result.environment_override?).to be(false)
        expect(result.environment_name).to eq(preserve_blank ? environment_name : nil)
      end
      expect(Setting.count).to eq(0)
      expect(Dir.children(File.dirname(key_path))).to be_empty
    end

    it "rejects invalid #{key} writes with secret-free errors and leaves rows and key untouched" do
      original = settings.resolve(key)
      invalid = [nil, true, 123, :symbol, '', ' ', "\u00A0", "private-credential\n", "private-credential\r",
                 "private-credential\0", "private-credential\t", "private-credential\u0001",
                 "private-credential\u007F", "private-credential\u0085",
                 "private-credential\xFF".force_encoding(Encoding::UTF_8)]
      invalid.each do |value|
        expect { settings.set(key, value) }.to raise_error(Service::Settings::ValidationError) { |error|
          expect(error.message)
            .to eq("#{environment_name} must be a valid, nonblank string without control characters.")
          expect(error.full_message).not_to include('private-credential')
          expect(error.cause).to be_nil
        }
        expect(settings.resolve(key)).to equal(original)
        expect(Setting.count).to eq(0)
        expect(File.exist?(key_path)).to be(false)
      end
      settings.set(key, 'stored-private-credential')
      stored = Setting[name: key.to_s].value
      expect { settings.set(key, "private-credential\n") }.to raise_error(Service::Settings::ValidationError)
      expect(Setting[name: key.to_s].value).to eq(stored)
    end
  end

  it 'never needs a key merely to resolve ordinary settings or ENV-only credentials' do
    settings.set(:loop_freq, 60)
    SpecSettingsSecrets::CREDENTIALS.each_value { |name, _| ENV[name] = 'env-private-credential' }

    config = Service::Helpers.new.env_variables

    expect(config[:loop_freq]).to eq(60)
    SpecSettingsSecrets::CREDENTIALS.each_key { |key| expect(config[key]).to eq('env-private-credential') }
    expect(Setting.count).to eq(1)
    expect(Dir.children(File.dirname(key_path))).to be_empty
  end

  it 'keeps injected ENV credentials and resolved secrets out of service diagnostics' do
    resolver = Service::Settings.new(environment: { 'GLUETUN_API_KEY' => 'private-credential' },
                                     encryption_key_path: key_path)
    expect(resolver.value(:gluetun_api_key)).to eq('private-credential')

    [resolver.inspect, resolver.to_s, resolver.to_json, PP.pp(resolver, +'')].each do |representation|
      expect(representation).not_to include('private-credential')
    end
  end

  it 'uses a fresh random nonce on every write and keeps the original persistent key' do
    settings.set(:qbit_pass, 'private-credential')
    first = Setting[name: 'qbit_pass'].value
    original_key = File.read(key_path)
    settings.set(:qbit_pass, 'private-credential')
    second = Setting[name: 'qbit_pass'].value

    expect(second).not_to eq(first)
    first_iv = Base64.strict_decode64(first.delete_prefix('enc:v1:')).byteslice(0, 12)
    second_iv = Base64.strict_decode64(second.delete_prefix('enc:v1:')).byteslice(0, 12)
    expect(second_iv).not_to eq(first_iv)
    expect(File.read(key_path)).to eq(original_key)
    expect(settings.value(:qbit_pass)).to eq('private-credential')
  end

  it 'preserves exact bytes and valid string encodings' do
    [' private-credential-é '.encode(Encoding::UTF_16LE), "private-credential\xFF".b].each do |plaintext|
      settings.set(:qbit_pass, plaintext)
      result = Service::Settings.new.value(:qbit_pass)
      expect(result).to eq(plaintext)
      expect(result.encoding).to eq(plaintext.encoding)
    end
  end

  it 'authenticates setting identity so copied ciphertext cannot resolve under a different setting' do
    settings.set(:qbit_pass, 'private-credential')
    stored = Setting[name: 'qbit_pass'].value
    Setting.create(name: 'gluetun_pass', value: stored)

    expect_safe_failure { Service::Settings.new.value(:gluetun_pass) }
    expect(Service::Settings.new.value(:qbit_pass)).to eq('private-credential')
    expect(Setting[name: 'gluetun_pass'].value).to eq(stored)
  end

  it 'rejects modifications to the nonce, tag, or ciphertext without changing storage' do
    settings.set(:qbit_pass, 'private-credential')
    stored = Setting[name: 'qbit_pass'].value
    original_payload = Base64.strict_decode64(stored.delete_prefix('enc:v1:'))
    [0, 12, 28, original_payload.bytesize - 1].each do |position|
      payload = original_payload.dup
      payload.setbyte(position, payload.getbyte(position) ^ 1)
      tampered = "enc:v1:#{Base64.strict_encode64(payload)}"
      Setting[name: 'qbit_pass'].update(value: tampered)
      expect_safe_failure { Service::Settings.new.value(:qbit_pass) }
      expect(Setting[name: 'qbit_pass'].value).to eq(tampered)
    end
  end

  ['private-credential', 'enc:v2:private-credential', 'enc:v1:%invalid-base64', 'enc:v1:',
   "enc:v1:YWJj\n", "enc:v1:#{Base64.strict_encode64('a' * 28)}",
   "enc:v1:#{Base64.strict_encode64('a' * 29)}"].each do |stored|
    it "fails closed for malformed or unsupported encrypted formats (#{stored.bytesize} bytes)" do
      Setting.create(name: 'qbit_pass', value: stored)

      expect_safe_failure { Service::Settings.new.value(:qbit_pass) }
      expect(Setting[name: 'qbit_pass'].value).to eq(stored)
      expect(File.exist?(key_path)).to be(false)
    end
  end

  it 'does not replace a missing key on secret reads or writes when dependent DB rows exist' do
    settings.set(:qbit_pass, 'private-credential')
    stored = Setting[name: 'qbit_pass'].value
    File.unlink(key_path)

    expect_safe_failure { Service::Settings.new.value(:qbit_pass) }
    expect_safe_failure { settings.set(:gluetun_api_key, 'another-private-credential') }
    expect_safe_failure { settings.set(:qbit_pass, 'replacement-private-credential') }
    expect(Setting.select_map(%i[name value])).to eq([['qbit_pass', stored]])
    expect(File.exist?(key_path)).to be(false)
  end

  it 'does not replace corrupt key material on reads or subsequent writes' do
    settings.set(:qbit_pass, 'private-credential')
    stored = Setting[name: 'qbit_pass'].value
    ['', 'private-key-invalid'].each do |key_material|
      File.write(key_path, key_material)
      expect_safe_failure { Service::Settings.new.value(:qbit_pass) }
      expect_safe_failure { settings.set(:gluetun_pass, 'another-private-credential') }
      expect(Setting.select_map(%i[name value])).to eq([['qbit_pass', stored]])
      expect(File.read(key_path)).to eq(key_material)
    end
  end

  it 'fails authentication with a different valid key and leaves both key and ciphertext untouched' do
    settings.set(:qbit_pass, 'private-credential')
    stored = Setting[name: 'qbit_pass'].value
    different_key = SecureRandom.hex(32)
    File.write(key_path, different_key)

    expect_safe_failure { Service::Settings.new.value(:qbit_pass) }
    expect(File.read(key_path)).to eq(different_key)
    expect(Setting[name: 'qbit_pass'].value).to eq(stored)
  end

  it 'clears only the requested credential, retains the key even after the last delete, and reuses it' do
    settings.set(:qbit_pass, 'qbit-private-credential')
    settings.set(:gluetun_pass, 'gluetun-private-credential')
    key_material = File.read(key_path)
    ENV['QBIT_PASS'] = 'env-private-credential'

    result = settings.delete(:qbit_pass)

    expect(result.value).to eq('env-private-credential')
    expect(result.environment_override?).to be(true)
    expect(Service::Settings.new.value(:gluetun_pass)).to eq('gluetun-private-credential')
    expect(File.read(key_path)).to eq(key_material)
    expect(settings.delete(:gluetun_pass).value).to be_nil
    expect(Setting.count).to eq(0)
    expect(File.read(key_path)).to eq(key_material)
    settings.set(:gluetun_pass, 'new-private-credential')
    expect(File.read(key_path)).to eq(key_material)
    expect(Service::Settings.new.value(:gluetun_pass)).to eq('new-private-credential')
  end

  it 'keeps existing resolver snapshots after other resolvers change or delete credentials' do
    settings.set(:qbit_pass, 'original-private-credential')
    snapshot = Service::Settings.new
    expect(snapshot.value(:qbit_pass)).to eq('original-private-credential')

    settings.set(:qbit_pass, 'new-private-credential')
    expect(snapshot.value(:qbit_pass)).to eq('original-private-credential')
    settings.delete(:qbit_pass)
    expect(snapshot.value(:qbit_pass)).to eq('original-private-credential')
    expect(Service::Settings.new.value(:qbit_pass)).to be_nil
  end

  it 'sanitizes database write failures that might contain encrypted material in their cause' do
    settings.set(:qbit_pass, 'original-private-credential')
    original = DB[:settings].first
    dataset = double('settings dataset')
    allow(Setting).to receive(:dataset).and_return(dataset)
    allow(dataset).to receive(:insert_conflict).and_raise(Sequel::DatabaseError, 'enc:v1:private-credential')

    expect_safe_failure { settings.set(:qbit_pass, 'private-credential') }
    expect(DB[:settings].all).to eq([original])
  end
end
