require 'bundler/setup'
Bundler.require(:default)

require 'base64'
require 'cgi'
require 'rack/mock'
require 'tmpdir'
require 'uri'
require_relative '../support/database_helper'
SpecDatabase.reset!

require_relative '../../service/helpers'
require_relative '../../framework/uptime'
require_relative '../../framework/web'
require_relative '../../framework/api'
require_relative '../../framework/session_secret'
require_relative '../../framework/session_middleware'
require_relative '../../framework/authentication'
require_relative '../../framework/application'

Framework::Web.set :environment, :test
Framework::Web.set :run, false
Framework::Web.set :views, File.expand_path('../../views', __dir__)
Framework::Web.set :public_folder, File.expand_path('../../public', __dir__)
Framework::Web.set :static, true

# Maintains a Rack cookie jar while exercising the complete qbop application.
class ApplicationSessionClient
  def initialize(app)
    @request = Rack::MockRequest.new(app)
  end

  def get(path, headers = {})
    record_cookie(@request.get(path, request_headers.merge(headers)))
  end

  def post(path, params = {}, headers = {})
    record_cookie(
      @request.post(
        path,
        request_headers.merge(
          headers,
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

RSpec.describe Framework::Application do # rubocop:disable Metrics/BlockLength
  def csrf_token(response)
    CGI.unescapeHTML(response.body.match(/name="_csrf" value="([^"]+)"/)[1])
  end

  def app
    described_class.build(session_secret_path: File.join(Dir.mktmpdir, 'session_secret.txt'))
  end

  def basic_auth(username = 'existing-user', password = 'existing-password')
    "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
  end

  def create_account
    Framework::Authentication.rodauth.create_account(
      login: 'admin@example.com', password: 'correct horse battery staple'
    )
  end

  def redirect_path(response)
    URI(response['location']).path
  end

  around do |example|
    keys = %w[WEB_AUTH_ENABLED BASIC_AUTH_ENABLED BASIC_AUTH_USER BASIC_AUTH_PASS]
    original_env = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| ENV.delete(key) }
    example.run
  ensure
    keys.each { |key| original_env[key].nil? ? ENV.delete(key) : ENV[key] = original_env[key] }
  end

  before do
    SpecDatabase.reset!
    %w[proton opnsense qbit].each do |name|
      source = Source.create(name: name)
      Stat.create(source_id: source.id, current_port: 12_345, same_port: 60, last_checked: Time.now)
    end
  end

  it 'directs a fresh installation to setup' do
    request = Rack::MockRequest.new(app)
    response = request.get('/')

    expect(response.status).to eq(302)
    expect(redirect_path(response)).to eq('/setup')
    expect(request.get('/setup').status).to eq(200)
  end

  it 'creates and authenticates the administrator through the real application stack' do
    client = ApplicationSessionClient.new(app)
    setup_page = client.get('/setup')
    setup_response = client.post(
      '/setup',
      login: 'admin@example.com',
      password: 'correct horse battery staple',
      'password-confirm': 'correct horse battery staple',
      _csrf: csrf_token(setup_page)
    )
    home = client.get('/')

    expect(setup_response.status).to eq(302)
    expect(redirect_path(setup_response)).to eq('/')
    expect(home.status).to eq(200)
    expect(home.body).to include('protonvpn', 'action="/logout"', 'sign out')
    expect(DB[:accounts].count).to eq(1)
    expect(client.get('/setup').status).to eq(404)
  end

  it 'requires login after an account has been provisioned' do
    create_account
    request = Rack::MockRequest.new(app)
    response = request.get('/history')

    expect(response.status).to eq(302)
    expect(redirect_path(response)).to eq('/login')
  end

  it 'allows login, logout, and then requires login again' do
    create_account
    client = ApplicationSessionClient.new(app)
    login_page = client.get('/login')
    invalid_login = client.post(
      '/login',
      login: 'admin@example.com', password: 'incorrect password', _csrf: csrf_token(login_page)
    )
    login_page = client.get('/login')
    login_response = client.post(
      '/login',
      login: 'admin@example.com', password: 'correct horse battery staple', _csrf: csrf_token(login_page)
    )
    home = client.get('/')
    logout_response = client.post('/logout', _csrf: csrf_token(home))
    protected_response = client.get('/')

    expect(invalid_login.status).to eq(401)
    expect(login_response.status).to eq(302)
    expect(redirect_path(login_response)).to eq('/')
    expect(home.status).to eq(200)
    expect(logout_response.status).to eq(302)
    expect(redirect_path(logout_response)).to eq('/login')
    expect(protected_response.status).to eq(302)
    expect(redirect_path(protected_response)).to eq('/login')
  end

  it 'serves authentication page assets without a session' do
    request = Rack::MockRequest.new(app)

    expect(request.get('/css/dark.css').status).to eq(200)
    expect(request.get('/images/dark/favicon-dark.svg').status).to eq(200)
  end

  it 'allows direct web access and makes setup unavailable when web authentication is disabled' do
    ENV['WEB_AUTH_ENABLED'] = 'false'
    request = Rack::MockRequest.new(app)
    home = request.get('/')

    expect(home.status).to eq(200)
    expect(home.body).not_to include('action="/logout"', 'sign out')
    expect(request.get('/history').status).to eq(200)
    expect(request.get('/setup').status).to eq(404)
    expect(request.post('/setup').status).to eq(404)
    expect(DB[:accounts].count).to eq(0)
  end

  it 'hides the logout control when web authentication is disabled for an existing session' do
    create_account
    client = ApplicationSessionClient.new(app)
    login_page = client.get('/login')
    client.post(
      '/login',
      login: 'admin@example.com', password: 'correct horse battery staple', _csrf: csrf_token(login_page)
    )

    ENV['WEB_AUTH_ENABLED'] = 'false'
    home = client.get('/')

    expect(home.status).to eq(200)
    expect(home.body).not_to include('action="/logout"', 'sign out')
  end

  it 'leaves the API public by default regardless of browser authentication' do
    ENV['BASIC_AUTH_ENABLED'] = 'false'
    request = Rack::MockRequest.new(app)
    expected_response = Rack::MockRequest.new(Framework::API).get('/api/stats')
    response = request.get('/api/stats')

    expect(response.status).to eq(expected_response.status)
    expect(response['content-type']).to eq(expected_response['content-type'])
    expect(response.body).to eq(expected_response.body)
    ENV['WEB_AUTH_ENABLED'] = 'false'
    expect(Rack::MockRequest.new(app).get('/api/stats').body).to eq(expected_response.body)
  end

  it 'protects only the API when Basic Auth is enabled' do
    ENV['BASIC_AUTH_ENABLED'] = 'true'
    ENV['BASIC_AUTH_USER'] = 'existing-user'
    ENV['BASIC_AUTH_PASS'] = 'existing-password'
    ENV['WEB_AUTH_ENABLED'] = 'false'
    request = Rack::MockRequest.new(app)

    expect(request.get('/').status).to eq(200)
    expect(request.get('/api/stats').status).to eq(401)
    expect(request.get('/api/stats', 'HTTP_AUTHORIZATION' => basic_auth('wrong', 'credentials')).status).to eq(401)
    expect(request.get('/api/stats', 'HTTP_AUTHORIZATION' => basic_auth).status).to eq(200)
    expect(request.get('/api/health', 'HTTP_AUTHORIZATION' => basic_auth).status).to eq(200)
    expect(request.get('/not-a-route').status).to eq(404)
  end

  it 'routes API paths directly to Grape instead of the browser stack' do
    expect(Framework::Web).not_to receive(:call)

    response = Rack::MockRequest.new(app).get('/api/stats')

    expect(response.status).to eq(200)
    expect(response.headers).not_to include('set-cookie')
  end

  it 'preserves the existing exact Basic Auth enablement semantics' do
    ENV['BASIC_AUTH_ENABLED'] = 'TRUE'
    request = Rack::MockRequest.new(app)

    expect(request.get('/api/stats').status).to eq(200)
  end

  it 'does not expose the former authentication routes' do
    ENV['WEB_AUTH_ENABLED'] = 'false'
    request = Rack::MockRequest.new(app)

    expect(request.get('/auth/login').status).to eq(404)
    expect(request.get('/auth/logout').status).to eq(404)
    expect(request.get('/auth/create-account').status).to eq(404)
    expect(request.post('/auth/create-account').status).to eq(404)
  end
end
