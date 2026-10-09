require 'bundler/setup'
Bundler.require(:default)
require 'webmock/rspec'
require 'stringio'
require_relative '../support/database_helper'
require_relative '../support/settings_secret_helper'
require_relative '../../service/seed'
require_relative '../../service/opnsense'
require_relative '../../service/qbit'
require_relative '../../jobs/qbop'

RSpec.describe 'Encrypted credentials in Qbop startup and job logs' do # rubocop:disable Metrics/BlockLength
  include_context 'encrypted settings'

  let(:job) { Qbop.allocate }
  let(:output) { StringIO.new }
  let(:logger) { Logger.new(output) }

  before do
    SpecDatabase.reset!
    settings.set(:port_source, 'gluetun')
    settings.set(:opnsense_skip, true)
    settings.set(:qbit_skip, true)
    Service::Seed.new
    allow_any_instance_of(Service::Helpers).to receive(:logger_instance).and_return(logger)
    allow(job).to receive(:sleep)
  end

  %i[missing_key corrupt_key tampered_ciphertext].each do |failure|
    it "keeps #{failure} details and secrets out of formatted SuckerPunch startup errors" do
      settings.set(:gluetun_api_key, 'private-db-api-credential')
      ciphertext = Setting[name: 'gluetun_api_key'].value
      key_material = File.read(key_path)
      case failure
      when :missing_key then File.unlink(key_path)
      when :corrupt_key then File.write(key_path, 'private-key-corrupt')
      when :tampered_ciphertext then Setting[name: 'gluetun_api_key'].update(value: 'enc:v1:private-ciphertext')
      end
      # On a cold start the same unreadable row must not prevent the web process from being seeded.
      Service::Seed.new
      allow(Qbop).to receive(:new).and_return(job)
      allow(SuckerPunch).to receive(:logger).and_return(logger)
      expect(job).not_to receive(:run_loop_iteration)

      Qbop.__run_perform

      expect(output.string).to include('Sucker Punch job error', 'Service::SettingsEncryptionKey::ConfigurationError')
      expect(output.string).not_to include('private-db-api-credential', 'private-key-corrupt', 'private-ciphertext',
                                           ciphertext, key_material, 'enc:v1:')
      expect(Setting[name: 'gluetun_api_key']).not_to be_nil
    end
  end

  it 'keeps a lone encrypted Basic credential out of actual formatted startup failures' do
    settings.set(:gluetun_user, 'private-db-basic-user')
    allow(Qbop).to receive(:new).and_return(job)
    allow(SuckerPunch).to receive(:logger).and_return(logger)
    expect(job).not_to receive(:run_loop_iteration)

    Qbop.__run_perform

    expect(output.string).to include('GLUETUN_USER and GLUETUN_PASS must both be configured for Basic authentication')
    expect(output.string).not_to include('private-db-basic-user', File.read(key_path), 'enc:v1:')
  end

  it 'keeps the startup credential snapshot and existing client after later writes and deletes' do
    settings.set(:gluetun_api_key, 'private-original-api-key')
    allow(Service::Gluetun).to receive(:new).and_call_original
    job.send(:initialize_dependencies)
    original_config = job.instance_variable_get(:@config).dup
    job.send(:log_startup)
    settings.set(:gluetun_api_key, 'private-replacement-api-key')
    settings.delete(:gluetun_api_key)
    expect(Qbop).not_to receive(:perform_async)
    request = stub_request(:get, 'http://gluetun:8000/v1/portforward')
              .with(headers: { 'X-API-Key' => 'private-original-api-key' }).to_return(body: '{"port":51820}')

    2.times { job.send(:run_loop_iteration) }

    expect(job.instance_variable_get(:@config)).to eq(original_config)
    expect(Service::Gluetun).to have_received(:new).once
    expect(request).to have_been_requested.twice
    expect(Service::Helpers.new.env_variables[:gluetun_api_key]).to be_nil
    expect(File.exist?(key_path)).to be(true)
    expect(output.string).to include('starting qbop', 'Gluetun returned')
    expect(output.string).not_to include('private-original-api-key', 'private-replacement-api-key', 'enc:v1:')
  end

  it 'keeps DB credentials and request exception details out of the formatted runtime job log' do
    settings.set(:gluetun_api_key, 'private-db-api-credential')
    job.send(:initialize_dependencies)
    details = "private-db-api-credential #{File.read(key_path)} enc:v1:private-ciphertext"
    stub_request(:get, 'http://gluetun:8000/v1/portforward')
      .to_raise(Faraday::ConnectionFailed.new(details))

    job.send(:run_loop_iteration)

    expect(output.string).to include('Gluetun control API request failed (Faraday::ConnectionFailed)')
    expect(output.string).not_to include('private-db-api-credential', File.read(key_path), 'enc:v1:private-ciphertext')
  end
end
