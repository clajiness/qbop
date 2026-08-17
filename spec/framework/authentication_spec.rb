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

  def post(path, params = {})
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

  def create_account
    described_class.rodauth.create_account(login: 'admin@example.com', password: 'correct horse battery staple')
  end

  around do |example|
    web_auth_enabled = ENV['WEB_AUTH_ENABLED']
    ENV.delete('WEB_AUTH_ENABLED')
    example.run
  ensure
    web_auth_enabled.nil? ? ENV.delete('WEB_AUTH_ENABLED') : ENV['WEB_AUTH_ENABLED'] = web_auth_enabled
  end

  before do
    SpecDatabase.reset!
    @client = AuthenticationSessionClient.new(build_app)
  end

  it 'renders a qbop-styled setup form with the intended fields' do
    response = @client.get('/setup')

    expect(response.status).to eq(200)
    expect(response.body).to include('Welcome to qbop', 'Create the administrator account', 'Create account')
    expect(response.body).to include('name="login"', 'name="password"', 'name="password-confirm"')
    expect(response.body).not_to include('name="login-confirm"')
  end

  it 'creates the single account, hashes its password, and authenticates the session' do
    setup_page = @client.get('/setup')
    response = @client.post(
      '/setup',
      login: 'admin@example.com',
      password: 'correct horse battery staple',
      'password-confirm': 'correct horse battery staple',
      _csrf: csrf_token(setup_page)
    )
    account = DB[:accounts].first
    password_hash = DB[:account_password_hashes].where(id: account[:id]).get(:password_hash)

    expect(response.status).to eq(302)
    expect(response['location']).to end_with('/')
    expect(account[:email]).to eq('admin@example.com')
    expect(password_hash).to start_with('$2')
    expect(password_hash).not_to include('correct horse battery staple')
    expect(@client.get('/auth-state').body).to match(/\Aauthenticated:\d+\z/)
  end

  it 'rejects setup submissions without a route-specific CSRF token' do
    response = @client.post(
      '/setup',
      login: 'admin@example.com',
      password: 'correct horse battery staple',
      'password-confirm': 'correct horse battery staple'
    )

    expect(response.status).to eq(403)
    expect(DB[:accounts].count).to eq(0)
  end

  it 'returns 404 for setup GET and POST after provisioning' do
    setup_page = @client.get('/setup')
    setup_params = {
      login: 'admin@example.com',
      password: 'correct horse battery staple',
      'password-confirm': 'correct horse battery staple',
      _csrf: csrf_token(setup_page)
    }
    @client.post('/setup', setup_params)

    expect(@client.get('/setup').status).to eq(404)
    expect(@client.post('/setup', setup_params.merge(login: 'other@example.com')).status).to eq(404)
    expect(DB[:accounts].count).to eq(1)
  end

  it 'returns 404 for setup GET and POST when web authentication is disabled' do
    ENV['WEB_AUTH_ENABLED'] = 'false'

    expect(@client.get('/setup').status).to eq(404)
    expect(@client.post('/setup').status).to eq(404)
    expect(DB[:accounts].count).to eq(0)
  end

  it 'keeps the database singleton protection effective for internal Rodauth requests' do
    create_account

    expect do
      described_class.rodauth.create_account(login: 'other@example.com', password: 'another secure password')
    end.to raise_error(Rodauth::InternalRequestError)

    expect(DB[:accounts].count).to eq(1)
    expect(DB[:account_password_hashes].count).to eq(1)
  end

  it 'redirects login to setup when no account exists' do
    response = @client.get('/login')

    expect(response.status).to eq(302)
    expect(response['location']).to end_with('/setup')
  end

  it 'renders a qbop-styled login form after provisioning' do
    create_account

    response = @client.get('/login')

    expect(response.status).to eq(200)
    expect(response.body).to include('Sign in to qbop', 'name="login"', 'name="password"')
    expect(response.body).not_to include('/setup')
  end

  it 'rejects an incorrect password and an unknown login' do
    create_account
    login_page = @client.get('/login')
    invalid_password = @client.post(
      '/login', login: 'admin@example.com', password: 'incorrect password', _csrf: csrf_token(login_page)
    )
    login_page = @client.get('/login')
    unknown_login = @client.post(
      '/login', login: 'unknown@example.com', password: 'incorrect password', _csrf: csrf_token(login_page)
    )

    expect(invalid_password.status).to eq(401)
    expect(invalid_password.body).to include('invalid password')
    expect(unknown_login.status).to eq(401)
    expect(unknown_login.body).to include('no matching login')
    expect(@client.get('/auth-state').body).to eq('anonymous')
  end

  it 'rejects login submissions without a route-specific CSRF token' do
    create_account

    response = @client.post(
      '/login', login: 'admin@example.com', password: 'correct horse battery staple'
    )

    expect(response.status).to eq(403)
    expect(@client.get('/auth-state').body).to eq('anonymous')
  end

  it 'authenticates valid credentials and recognizes the session later' do
    create_account
    login_page = @client.get('/login')
    response = @client.post(
      '/login',
      login: 'admin@example.com', password: 'correct horse battery staple', _csrf: csrf_token(login_page)
    )

    expect(response.status).to eq(302)
    expect(@client.get('/auth-state').body).to match(/\Aauthenticated:\d+\z/)
  end

  it 'rejects logout without CSRF and invalidates the session after a valid logout' do
    create_account
    login_page = @client.get('/login')
    @client.post(
      '/login',
      login: 'admin@example.com', password: 'correct horse battery staple', _csrf: csrf_token(login_page)
    )

    expect(@client.post('/logout').status).to eq(403)
    expect(@client.get('/auth-state').body).to match(/\Aauthenticated:\d+\z/)

    logout_page = @client.get('/logout')
    response = @client.post('/logout', _csrf: csrf_token(logout_page))

    expect(response.status).to eq(302)
    expect(response['location']).to end_with('/login')
    expect(@client.get('/auth-state').body).to eq('anonymous')
  end
end
