require 'bundler/setup'
Bundler.require(:default)

require 'cgi'
require 'rack/mock'
require_relative '../support/database_helper'
SpecDatabase.reset!

require_relative '../../service/helpers'
require_relative '../../framework/session_middleware'
require_relative '../../framework/authentication'

# Maintains a Rack cookie jar while exercising Rodauth's real routes.
class AuthenticationSessionClient
  def initialize(app)
    @request = Rack::MockRequest.new(app)
  end

  def get(path)
    record_cookie(@request.get(path, request_headers))
  end

  def post(path, params)
    record_cookie(
      @request.post(
        path,
        request_headers.merge(
          'CONTENT_TYPE' => 'application/x-www-form-urlencoded',
          input: Rack::Utils.build_query(params)
        )
      )
    )
  end

  private

  def request_headers
    @cookie ? { 'HTTP_COOKIE' => @cookie } : {}
  end

  def record_cookie(response)
    if (set_cookie = response.get_header('set-cookie'))
      @cookie = set_cookie.split(';', 2).first
    end
    response
  end
end

RSpec.describe Framework::Authentication do # rubocop:disable Metrics/BlockLength
  def csrf_token(response)
    CGI.unescapeHTML(response.body.match(/name="_csrf" value="([^"]+)"/)[1])
  end

  def build_app
    downstream = lambda do |env|
      auth = env.fetch('rodauth')
      body = auth.logged_in? ? "authenticated:#{auth.account![:id]}" : 'anonymous'
      [200, { 'content-type' => 'text/plain' }, [body]]
    end

    Rack::Builder.new do
      use Framework::SessionMiddleware, secret: 's' * 64
      use Framework::Authentication
      run downstream
    end.to_app
  end

  before do
    SpecDatabase.reset!
    described_class.rodauth.create_account(login: 'admin@example.com', password: 'correct horse battery staple')
    @client = AuthenticationSessionClient.new(build_app)
  end

  it 'creates the single account internally with a bcrypt password hash' do
    account = DB[:accounts].first
    password_hash = DB[:account_password_hashes].where(id: account[:id]).get(:password_hash)

    expect(account[:email]).to eq('admin@example.com')
    expect(password_hash).to start_with('$2')
    expect(password_hash).not_to include('correct horse battery staple')
  end

  it 'rejects a second account through the internal Rodauth path' do
    expect do
      described_class.rodauth.create_account(login: 'other@example.com', password: 'another secure password')
    end.to raise_error(Rodauth::InternalRequestError)

    expect(DB[:accounts].count).to eq(1)
    expect(DB[:account_password_hashes].count).to eq(1)
  end

  it 'rejects an incorrect password without authenticating the session' do
    login_page = @client.get('/auth/login')
    response = @client.post(
      '/auth/login',
      login: 'admin@example.com', password: 'incorrect password', _csrf: csrf_token(login_page)
    )

    expect(response.status).to eq(401)
    expect(response.body).to include('invalid password')
    expect(@client.get('/auth-state').body).to eq('anonymous')
  end

  it 'rejects login submissions without a route-specific CSRF token' do
    response = @client.post(
      '/auth/login', login: 'admin@example.com', password: 'correct horse battery staple'
    )

    expect(response.status).to eq(403)
    expect(@client.get('/auth-state').body).to eq('anonymous')
  end

  it 'authenticates the password and recognizes the session on a later request' do
    login_page = @client.get('/auth/login')
    response = @client.post(
      '/auth/login',
      login: 'admin@example.com', password: 'correct horse battery staple', _csrf: csrf_token(login_page)
    )

    expect(response.status).to eq(302)
    expect(@client.get('/auth-state').body).to match(/\Aauthenticated:\d+\z/)
  end

  it 'logs out the authenticated session' do
    login_page = @client.get('/auth/login')
    @client.post(
      '/auth/login',
      login: 'admin@example.com', password: 'correct horse battery staple', _csrf: csrf_token(login_page)
    )
    logout_page = @client.get('/auth/logout')

    response = @client.post('/auth/logout', _csrf: csrf_token(logout_page))

    expect(response.status).to eq(302)
    expect(@client.get('/auth-state').body).to eq('anonymous')
  end
end
