require 'bundler/setup'
Bundler.require(:default)

require_relative '../../service/github'

RSpec.describe Service::Github do # rubocop:disable Metrics/BlockLength
  let(:request_class) do
    Class.new(Struct.new(:headers, :url_path)) do
      def initialize
        super({}, nil)
      end

      def url(path)
        self.url_path = path
      end
    end
  end

  let(:conn) { instance_double(Faraday::Connection) }
  let(:request) { request_class.new }

  before do
    allow(Faraday).to receive(:new).and_return(conn)
  end

  describe '#get_most_recent_tag' do
    it 'returns the most recent tag from GitHub' do
      response = instance_double(
        Faraday::Response,
        body: '[{"name":"v2.7.0"},{"name":"v2.6.0"}]',
        success?: true
      )

      allow(conn).to receive(:get).and_yield(request).and_return(response)

      most_recent_tag = described_class.new.get_most_recent_tag

      expect(request.url_path).to eq('/repos/clajiness/qbop/tags')
      expect(request.headers['Accept']).to eq('application/vnd.github+json')
      expect(most_recent_tag).to eq('v2.7.0')
    end

    it 'returns nil when GitHub returns an error' do
      response = instance_double(Faraday::Response, body: '{}', success?: false)

      allow(conn).to receive(:get).and_yield(request).and_return(response)

      expect(described_class.new.get_most_recent_tag).to eq(nil)
    end
  end
end
