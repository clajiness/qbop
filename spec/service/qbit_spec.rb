require 'bundler/setup'
Bundler.require(:default)

require_relative '../../service/qbit'

RSpec.describe Service::Qbit do # rubocop:disable Metrics/BlockLength
  let(:request_class) do
    Class.new(Struct.new(:headers, :body, :url_path)) do
      def initialize
        super({}, nil, nil)
      end

      def url(path)
        self.url_path = path
      end
    end
  end

  let(:conn) { instance_double(Faraday::Connection) }
  let(:request) { request_class.new }
  let(:config) do
    {
      qbit_addr: 'https://qbittorrent.local',
      qbit_user: 'test_user',
      qbit_pass: 'test_pass',
      qbit_ssl_verify: false
    }
  end

  before do
    allow(Faraday).to receive(:new).and_return(conn)
  end

  describe '#qbt_app_preferences' do
    it 'uses bearer authentication when an API key is configured' do
      config[:qbit_api_key] = 'qbt_test_key'
      response = instance_double(Faraday::Response, body: '{"listen_port": 12345}')

      allow(conn).to receive(:get).and_yield(request).and_return(response)

      qbit = described_class.new(config)
      expect(qbit).not_to receive(:qbt_auth_login)

      expect(qbit.qbt_app_preferences).to eq(12_345)
      expect(request.url_path).to eq('/api/v2/app/preferences')
      expect(request.headers['Authorization']).to eq('Bearer qbt_test_key')
      expect(request.headers).not_to have_key('Cookie')
    end

    it 'uses cookie authentication when no API key is configured' do
      response = instance_double(Faraday::Response, body: '{"listen_port": 12345}')

      allow(conn).to receive(:get).and_yield(request).and_return(response)

      qbit = described_class.new(config)
      allow(qbit).to receive(:qbt_auth_login).and_return('SID=test_sid')

      expect(qbit.qbt_app_preferences).to eq(12_345)
      expect(request.headers['Cookie']).to eq('SID=test_sid')
      expect(request.headers).not_to have_key('Authorization')
    end
  end

  describe '#qbt_app_set_preferences' do
    it 'uses bearer authentication when setting preferences with an API key' do
      config[:qbit_api_key] = 'qbt_test_key'
      response = instance_double(Faraday::Response)

      allow(conn).to receive(:post).and_yield(request).and_return(response)

      described_class.new(config).qbt_app_set_preferences(54_321)

      expect(request.url_path).to eq('/api/v2/app/setPreferences')
      expect(request.headers['Authorization']).to eq('Bearer qbt_test_key')
      expect(request.headers['Content-Type']).to eq('application/x-www-form-urlencoded')
      expect(request.body).to eq('json=%7B%22listen_port%22%3A54321%7D')
    end
  end
end
