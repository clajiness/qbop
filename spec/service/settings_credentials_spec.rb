require 'bundler/setup'
Bundler.require(:default)
require 'webmock/rspec'
require_relative '../support/database_helper'
require_relative '../support/settings_secret_helper'
require_relative '../../service/helpers'
require_relative '../../service/gluetun'
require_relative '../../service/opnsense'
require_relative '../../service/qbit'

RSpec.describe 'Integration authentication with encrypted settings' do # rubocop:disable Metrics/BlockLength
  include_context 'encrypted settings'

  before { SpecDatabase.reset! }

  def config
    Service::Helpers.new.env_variables
  end

  describe 'Gluetun' do # rubocop:disable Metrics/BlockLength
    let(:endpoint) { 'http://gluetun:8000/v1/portforward' }

    it 'uses an encrypted DB API key for X-API-Key authentication' do
      settings.set(:gluetun_api_key, 'db-api-private')
      request = stub_request(:get, endpoint).with(headers: { 'X-API-Key' => 'db-api-private' }) do |req|
        !req.headers.key?('Authorization')
      end.to_return(body: '{"port":51820}')

      expect(Service::Gluetun.new(config).current_port).to eq(51_820)
      expect(request).to have_been_requested.once
    end

    it 'uses encrypted DB Basic credentials without stripping meaningful spaces' do
      settings.set(:gluetun_user, ' db-user-private ')
      settings.set(:gluetun_pass, ' db-pass-private ')
      request = stub_request(:get, endpoint).with(basic_auth: [' db-user-private ', ' db-pass-private '])
                                            .to_return(body: '{"port":51820}')

      expect(Service::Gluetun.new(config).current_port).to eq(51_820)
      expect(request).to have_been_requested.once
    end

    it 'keeps ENV API-key precedence over encrypted Basic credentials' do
      settings.set(:gluetun_user, 'db-user-private')
      settings.set(:gluetun_pass, 'db-pass-private')
      ENV['GLUETUN_API_KEY'] = 'env-api-private'
      request = stub_request(:get, endpoint).with(headers: { 'X-API-Key' => 'env-api-private' }) do |req|
        !req.headers.key?('Authorization')
      end.to_return(body: '{"port":51820}')

      expect(Service::Gluetun.new(config).current_port).to eq(51_820)
      expect(request).to have_been_requested.once
    end

    it 'combines an authoritative ENV username with an encrypted DB password' do
      settings.set(:gluetun_user, 'db-user-private')
      settings.set(:gluetun_pass, 'db-pass-private')
      ENV['GLUETUN_USER'] = 'env-user-private'
      request = stub_request(:get, endpoint).with(basic_auth: %w[env-user-private db-pass-private])
                                            .to_return(body: '{"port":51820}')

      expect(Service::Gluetun.new(config).current_port).to eq(51_820)
      expect(request).to have_been_requested.once
    end

    %i[gluetun_user gluetun_pass].each do |key|
      it "rejects a lone resolved #{key} with the existing static configuration error" do
        settings.set(key, 'db-basic-private')

        expect { Service::Gluetun.new(config) }.to raise_error(Service::Gluetun::PortError) do |error|
          expect(error.message)
            .to eq('GLUETUN_USER and GLUETUN_PASS must both be configured for Basic authentication')
          expect(error.full_message).not_to include('db-basic-private')
          expect(error.cause).to be_nil
        end
      end
    end

    it 'keeps DB API-key precedence over an incomplete Basic pair' do
      settings.set(:gluetun_api_key, 'db-api-private')
      settings.set(:gluetun_user, 'db-user-private')
      request = stub_request(:get, endpoint).with(headers: { 'X-API-Key' => 'db-api-private' })
                                            .to_return(body: '{"port":51820}')

      expect(Service::Gluetun.new(config).current_port).to eq(51_820)
      expect(request).to have_been_requested.once
    end

    it 'retains unauthenticated mode with absent credentials and no key file' do
      request = stub_request(:get, endpoint).with do |req|
        !req.headers.key?('Authorization') && !req.headers.key?('X-API-Key')
      end.to_return(body: '{"port":51820}')

      expect(Service::Gluetun.new(config).current_port).to eq(51_820)
      expect(request).to have_been_requested.once
      expect(File.exist?(key_path)).to be(false)
      expect(Setting.count).to eq(0)
    end
  end

  describe 'qBittorrent' do # rubocop:disable Metrics/BlockLength
    let(:endpoint) { 'http://qbit:8080/api/v2/app/preferences' }

    before { settings.set(:qbit_addr, 'http://qbit:8080') }

    it 'uses an encrypted DB API key for the existing Bearer authentication' do
      settings.set(:qbit_api_key, 'db-qbit-api-private')
      request = stub_request(:get, endpoint).with(headers: { 'Authorization' => 'Bearer db-qbit-api-private' })
                                            .to_return(body: '{"listen_port":51820}')

      expect(Service::Qbit.new(config).qbt_app_preferences).to eq(51_820)
      expect(request).to have_been_requested.once
      expect(a_request(:post, 'http://qbit:8080/api/v2/auth/login')).not_to have_been_made
    end

    it 'uses encrypted username/password credentials for the existing login and cookie flow' do
      settings.set(:qbit_user, ' db-qbit-user-private ')
      settings.set(:qbit_pass, ' db-qbit-pass-private ')
      login = stub_request(:post, 'http://qbit:8080/api/v2/auth/login')
              .with(body: { 'username' => ' db-qbit-user-private ', 'password' => ' db-qbit-pass-private ' })
              .to_return(headers: { 'Set-Cookie' => 'SID=db-session; path=/' })
      request = stub_request(:get, endpoint).with(headers: { 'Cookie' => 'SID=db-session' })
                                            .to_return(body: '{"listen_port":51820}')

      expect(Service::Qbit.new(config).qbt_app_preferences).to eq(51_820)
      expect(login).to have_been_requested.once
      expect(request).to have_been_requested.once
    end

    it 'keeps ENV API-key precedence over encrypted username/password credentials' do
      settings.set(:qbit_user, 'db-qbit-user-private')
      settings.set(:qbit_pass, 'db-qbit-pass-private')
      ENV['QBIT_API_KEY'] = 'env-qbit-api-private'
      request = stub_request(:get, endpoint).with(headers: { 'Authorization' => 'Bearer env-qbit-api-private' })
                                            .to_return(body: '{"listen_port":51820}')

      expect(Service::Qbit.new(config).qbt_app_preferences).to eq(51_820)
      expect(request).to have_been_requested.once
      expect(a_request(:post, 'http://qbit:8080/api/v2/auth/login')).not_to have_been_made
    end
  end

  describe 'OPNsense' do # rubocop:disable Metrics/BlockLength
    before do
      settings.set(:opnsense_interface_addr, 'https://firewall')
      settings.set(:opnsense_alias_name, 'vpn_alias')
      settings.set(:opnsense_api_key, 'db-opn-key-private')
      settings.set(:opnsense_api_secret, 'db-opn-secret-private')
    end

    it 'uses encrypted DB API key/secret in the existing Basic-auth client' do
      request = stub_request(:get, 'https://firewall/api/firewall/alias/get_alias_uuid/vpn_alias')
                .with(basic_auth: %w[db-opn-key-private db-opn-secret-private]).to_return(body: '{"uuid":"alias-id"}')

      expect(Service::Opnsense.new(config).get_alias_uuid).to eq('alias-id')
      expect(request).to have_been_requested.once
    end

    it 'keeps ENV API key/secret authoritative over encrypted DB credentials' do
      ENV.update('OPN_API_KEY' => 'env-opn-key-private', 'OPN_API_SECRET' => 'env-opn-secret-private')
      request = stub_request(:get, 'https://firewall/api/firewall/alias/get_alias_uuid/vpn_alias')
                .with(basic_auth: %w[env-opn-key-private env-opn-secret-private]).to_return(body: '{"uuid":"alias-id"}')

      expect(Service::Opnsense.new(config).get_alias_uuid).to eq('alias-id')
      expect(request).to have_been_requested.once
    end

    it 'feeds the same encrypted DB credentials to WireGuard target operations' do
      requests = %w[server/search_server client/search_client].map do |path|
        stub_request(:get, "https://firewall/api/wireguard/#{path}?rowCount=-1")
          .with(basic_auth: %w[db-opn-key-private db-opn-secret-private]).to_return(body: '{"rows":[]}')
      end

      expect(Service::Opnsense.new(config).wireguard_targets).to eq(instances: [], peers: [])
      requests.each { |request| expect(request).to have_been_requested.once }
    end
  end
end
