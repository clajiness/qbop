require 'bundler/setup'
Bundler.require(:default)

require 'rack/mock'
require_relative '../../framework/session_middleware'

RSpec.describe Framework::SessionMiddleware do # rubocop:disable Metrics/BlockLength
  let(:downstream_app) do
    lambda do |env|
      env.fetch('rack.session')['test'] = 'session-value'
      [200, { 'content-type' => 'text/plain' }, ['ok']]
    end
  end

  let(:app) { described_class.new(downstream_app, secret: 's' * 64) }

  it 'configures encrypted sessions through the secrets option' do
    http = app.instance_variable_get(:@http)
    https = app.instance_variable_get(:@https)

    expect(http.instance_variable_get(:@encryptors).length).to eq(1)
    expect(https.instance_variable_get(:@encryptors).length).to eq(1)
    expect(http.instance_variable_get(:@legacy_hmac_secret)).to be_nil
    expect(https.instance_variable_get(:@legacy_hmac_secret)).to be_nil
  end

  it 'uses HttpOnly SameSite=Lax cookies over HTTP' do
    cookie = Rack::MockRequest.new(app).get('/').get_header('set-cookie')
    attributes = cookie.split(';').map(&:strip)

    expect(cookie).to include('qbop.session=', 'httponly', 'samesite=lax')
    expect(attributes).not_to include('secure')
    expect(cookie).not_to include('session-value')
  end

  it 'adds Secure to cookies for HTTPS requests' do
    cookie = Rack::MockRequest.new(app).get('https://example.org/').get_header('set-cookie')

    expect(cookie.split(';').map(&:strip)).to include('secure')
  end

  it 'recognizes HTTPS terminated by a reverse proxy' do
    cookie = Rack::MockRequest.new(app).get('/', 'HTTP_X_FORWARDED_PROTO' => 'https').get_header('set-cookie')

    expect(cookie.split(';').map(&:strip)).to include('secure')
  end
end
