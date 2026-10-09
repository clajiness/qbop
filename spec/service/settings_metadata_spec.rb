require 'bundler/setup'
Bundler.require(:default)
require 'logger'
require 'stringio'
require_relative '../support/database_helper'
require_relative '../support/settings_secret_helper'
require_relative '../../service/settings_presentation'

RSpec.describe 'Safe settings metadata and presentation' do # rubocop:disable Metrics/BlockLength
  include_context 'encrypted settings'

  before { SpecDatabase.reset! }

  let(:presentation) { Service::SettingsPresentation.new(settings: settings) }

  def settings_queries
    output = StringIO.new
    logger = Logger.new(output)
    DB.loggers << logger
    yield
    output.string.lines.select { |line| line.match?(/SELECT.*FROM [`"\[]?settings/i) }
  ensure
    DB.loggers.delete(logger)
  end

  it 'uses two bulk queries for both one section and all 25 settings' do
    groups = Service::SettingsPresentation.const_get(:GROUPS)
    [groups.slice('Application'), groups].each do |shown_groups|
      stub_const('Service::SettingsPresentation::GROUPS', shown_groups)
      entries = nil

      queries = settings_queries { entries = presentation.sections.values.flatten }

      expect(entries.size).to eq(shown_groups.values.sum(&:size))
      expect(queries.size).to eq(2)
    end
  end

  it 'bulk-loads secret names without selecting ciphertext or decrypting credentials' do
    SpecSettingsSecrets::CREDENTIALS.each_key do |key|
      Setting.create(name: key.to_s, value: 'enc:v1:unreadable-private-ciphertext')
    end
    expect(Service::SettingsEncryption).not_to receive(:new)
    entries = nil

    queries = settings_queries { entries = presentation.sections.values.flatten }

    value_query = queries.find { |query| query.include?('`value`') }
    expect(value_query).not_to include(*SpecSettingsSecrets::CREDENTIALS.keys.map(&:to_s))
    expect(queries.reject { |query| query == value_query }.first).to include('SELECT `name` FROM')
    expect(entries.select(&:secret?)).to all(have_attributes(value: nil, source: :database))
    expect(entries.select(&:secret?)).to all(be_database_value_present)
    expect(entries.inspect).not_to include('private-ciphertext', 'enc:v1:')
    expect(Dir.children(File.dirname(key_path))).to be_empty
  end

  it 'preserves precedence, legacy blanks and inactive overrides in bulk metadata' do
    settings.set(:qbit_addr, 'http://inactive-private-qbit:8080')
    settings.set(:ui_mode, 'light')
    settings.set(:opnsense_alias_name, 'stored_alias')
    settings.set(:opnsense_skip, true)
    settings.set(:port_source, 'gluetun')
    Setting.create(name: 'qbit_pass', value: 'enc:v1:unreadable-private-ciphertext')
    ENV.update('QBIT_ADDR' => 'http://env-qbit:8080', 'UI_MODE' => '', 'OPN_ALIAS_NAME' => ' ',
               'OPN_PROTON_ALIAS_NAME' => 'legacy_alias', 'OPN_SKIP' => 'false', 'PORT_SOURCE' => '')
    expect(Service::SettingsEncryption).not_to receive(:new)

    metadata = settings.all_metadata

    expect(metadata.keys).to eq(Service::Settings.keys)
    expect(metadata[:qbit_addr]).to have_attributes(
      value: 'http://env-qbit:8080', source: :environment, database_value_present: true, environment_override: true
    )
    expect(metadata[:ui_mode]).to have_attributes(value: 'light', source: :database)
    expect(metadata[:opnsense_alias_name]).to have_attributes(
      value: 'legacy_alias', environment_name: 'OPN_PROTON_ALIAS_NAME'
    )
    expect(metadata[:opnsense_skip]).to have_attributes(value: 'false', environment_override: true)
    expect(metadata[:port_source]).to have_attributes(value: '', environment_override: true)
    expect(metadata[:qbit_pass]).to have_attributes(value: nil, source: :database, database_value_present: true)
    expect(metadata.inspect).not_to include('inactive-private-qbit', 'private-ciphertext')
    metadata.each { |key, entry| expect(entry).to eq(settings.metadata(key)) }
  end

  it 'reads new database state on each bulk call without changing runtime resolver snapshots' do
    settings.value(:loop_freq)
    expect(settings.all_metadata[:loop_freq]).to have_attributes(value: 45, source: :default)
    writer = Service::Settings.new
    writer.set(:loop_freq, 60)
    expect(settings.all_metadata[:loop_freq]).to have_attributes(value: 60, source: :database)
    writer.delete(:loop_freq)

    expect(settings.all_metadata[:loop_freq]).to have_attributes(value: 45, source: :default)
    expect(settings.value(:loop_freq)).to eq(45)
  end

  it 'presents precisely the 25 registry settings in the expected groups without importing defaults' do
    sections = presentation.sections
    entries = sections.values.flatten

    expect(sections.keys).to eq(%w[Application ProtonVPN Gluetun OPNsense qBittorrent Logging])
    expect(entries.map(&:key)).to match_array(Service::Settings.keys)
    expect(entries.size).to eq(25)
    expect(entries.count(&:secret?)).to eq(8)
    expect(entries).to all(have_attributes(description: a_string_matching(/\S/)))
    expect(presentation.find('opn_proton_alias_name')).to be_nil
    expect(presentation.find('oidc_client_secret')).to be_nil
    expect(presentation.find('unknown')).to be_nil
    expect(Setting.count).to eq(0)
    expect(Dir.children(File.dirname(key_path))).to be_empty
  end

  it 'exposes defaults, numeric bounds, select choices and absent states from the registry' do
    frequency = settings.metadata(:loop_freq)
    expect(frequency.value).to eq(45)
    expect(frequency.default_value).to eq(45)
    expect(frequency.default?).to be(true)
    expect(frequency.unset?).to be(false)
    expect(frequency.database_value_present?).to be(false)
    expect(frequency.minimum).to eq(1)
    expect(frequency.maximum).to be_nil
    expect(settings.metadata(:required_attempts)).to have_attributes(minimum: 1, maximum: 10)
    expect(settings.metadata(:log_lines)).to have_attributes(minimum: 1, maximum: 5000)
    expect(settings.metadata(:port_source).choices).to eq(%w[proton gluetun])
    expect(settings.metadata(:qbit_addr).unset?).to be(true)
  end

  SpecSettingsSecrets::CREDENTIALS.each do |key, (environment_name, _)|
    it "reports #{key} presence and source without decrypting or returning credentials" do
      settings.set(key, 'database-private-credential')
      File.unlink(key_path)
      Setting[name: key.to_s].update(value: 'malformed-ciphertext-private')
      expect(Service::SettingsEncryption).not_to receive(:new)
      expect(Setting).not_to receive(:[])

      expect(Service::Settings.new.database_value_present?(key)).to be(true)
      metadata = Service::Settings.new.metadata(key)
      expect(metadata.value).to be_nil
      expect(metadata.source).to eq(:database)
      expect(metadata.database_value_present?).to be(true)
      expect(metadata.environment_override?).to be(false)
      expect(metadata.secret?).to be(true)
      expect(metadata.unset?).to be(false)
      ENV[environment_name] = 'env-private-credential'
      metadata = Service::Settings.new.metadata(key)
      expect(metadata.environment_override?).to be(true)
      expect(metadata.environment_name).to eq(environment_name)
      expect(metadata.database_value_present?).to be(true)
      expect(metadata.value).to be_nil
      expect(metadata.inspect).not_to include('private-credential', 'ciphertext-private')
    end
  end

  it 'keeps metadata inspection independent of runtime resolution and its plaintext cache' do
    settings.set(:qbit_pass, 'database-private-credential')
    expect(settings.value(:qbit_pass)).to eq('database-private-credential')

    metadata = settings.metadata(:qbit_pass)

    expect(metadata.value).to be_nil
    expect(metadata.to_h.values).not_to include('database-private-credential')
    expect(settings.value(:qbit_pass)).to eq('database-private-credential')
  end

  it 'reports a DB override underneath authoritative ENV without revealing its inactive value' do
    settings.set(:qbit_addr, 'http://stored-qbit:8080')
    ENV['QBIT_ADDR'] = 'http://environment-qbit:8080'

    entry = presentation.find('qbit_addr')

    expect(entry.value).to eq('http://environment-qbit:8080')
    expect(entry.environment_override?).to be(true)
    expect(entry.database_value_present?).to be(true)
    expect(entry.metadata.inspect).not_to include('stored-qbit')
  end

  it 'treats ignorable legacy blanks as editable and absent secrets as not configured' do
    ENV.update('UI_MODE' => '', 'QBIT_USER' => '', 'GLUETUN_USER' => ' ')

    %w[ui_mode qbit_user gluetun_user].each do |key|
      entry = presentation.find(key)
      expect(entry.environment_override?).to be(false)
      expect(entry.source_label).to eq('Not configured')
      expect(entry.unset?).to be(true)
    end
  end

  it 'keeps blank PORT_SOURCE authoritative and invalid, and identifies the actual alias ENV winner' do
    ENV.update('PORT_SOURCE' => '', 'OPN_ALIAS_NAME' => ' ', 'OPN_PROTON_ALIAS_NAME' => 'legacy_alias')

    source = presentation.find('port_source')
    expect(source.environment_override?).to be(true)
    expect(source.invalid_port_source?).to be(true)
    expect(source.environment_name).to eq('PORT_SOURCE')
    alias_entry = presentation.find('opnsense_alias_name')
    expect(alias_entry.environment_override?).to be(true)
    expect(alias_entry.environment_name).to eq('OPN_PROTON_ALIAS_NAME')
  end

  it 'keeps meaningful false booleans ENV-managed and gives editors explicit true/false choices' do
    ENV.update('OPN_SKIP' => 'false', 'LOG_REVERSE' => 'yes', 'QBIT_SSL_VERIFY' => 'false')

    %w[opnsense_skip log_reverse qbit_ssl_verify].each do |key|
      entry = presentation.find(key)
      expect(entry.environment_override?).to be(true)
      expect(entry.input_value).to eq('false')
      expect(entry.input_choices).to eq(%w[true false])
    end
  end

  it 'requires restart for job/client/logger settings and permits dynamic browser settings without restart' do
    entries = presentation.sections.values.flatten
    expect(entries.reject(&:restart_required?).map(&:key)).to match_array(%i[ui_mode log_lines log_reverse])
    expect(entries.select(&:restart_required?).size).to eq(22)
    expect(presentation.find('log_to_stdout').restart_required?).to be(true)
  end

  it 'uses select, number, URL, text and password controls according to the registry' do
    { port_source: 'select', ui_mode: 'select', qbit_skip: 'select', log_lines: 'number',
      qbit_addr: 'url', proton_gateway: 'text', opnsense_alias_name: 'text', qbit_user: 'password' }
      .each { |key, type| expect(presentation.find(key.to_s).input_type).to eq(type) }
  end
end
