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

  def csrf_token_for(response, action)
    form = response.body.match(%r{<form action="#{Regexp.escape(action)}" method="post".*?</form>}m)[0]
    CGI.unescapeHTML(form.match(/name="_csrf" value="([^"]+)"/)[1])
  end

  def app
    described_class.build(session_secret_path: File.join(Dir.mktmpdir, 'session_secret.txt'))
  end

  def basic_auth(username = 'existing-user', password = 'existing-password')
    "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
  end

  def bearer_auth(token)
    { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }
  end

  def create_account
    Framework::Authentication.rodauth.create_account(
      login: 'admin@example.com', password: 'correct horse battery staple'
    )
  end

  def login(client, email: 'admin@example.com', password: 'correct horse battery staple')
    login_page = client.get('/login')
    client.post(
      '/login',
      login: email, password: password, _csrf: csrf_token(login_page)
    )
  end

  def change_email(client, page, email: 'new-admin@example.com')
    client.post(
      '/account/change-email',
      login: email,
      password: 'correct horse battery staple',
      _csrf: csrf_token_for(page, '/account/change-email')
    )
  end

  def change_password(client, page, password: 'even better horse battery staple')
    client.post(
      '/account/change-password',
      password: 'correct horse battery staple',
      'new-password': password,
      'password-confirm': password,
      _csrf: csrf_token_for(page, '/account/change-password')
    )
  end

  def redirect_path(response)
    URI(response['location']).path
  end

  around do |example|
    keys = %w[
      WEB_AUTH_ENABLED BASIC_AUTH_ENABLED BASIC_AUTH_USER BASIC_AUTH_PASS
      OIDC_ENABLED OIDC_AUTO_REDIRECT LOCAL_LOGIN_ENABLED OIDC_ISSUER
      OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_PUBLIC_URL
    ]
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
    expect(home.body).not_to include('href="/account"')
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

  it 'provides a minimal account page only to authenticated users' do
    create_account
    anonymous = Rack::MockRequest.new(app)
    anonymous_response = anonymous.get('/account')

    expect(anonymous_response.status).to eq(302)
    expect(redirect_path(anonymous_response)).to eq('/login')

    client = ApplicationSessionClient.new(app)
    login(client)
    account_page = client.get('/account')

    expect(account_page.status).to eq(200)
    expect(account_page.body).to include(
      '<h4><em>account</em></h4>',
      'current email: admin@example.com',
      '<legend>change email</legend>',
      '<legend>change password</legend>',
      'action="/account/change-email"',
      'action="/account/change-password"'
    )
    expect(account_page.body).not_to include('href="/account"')
    expect(account_page.body).not_to include('style=')

    about_page = client.get('/about')
    expect(about_page.body).to include('<h4><em>account</em></h4>', 'href="/account"')
    expect(about_page.body).to include('OIDC_ENABLED', 'OIDC_ISSUER', 'LOCAL_LOGIN_ENABLED')
    account_position = about_page.body.index('<h4><em>account</em></h4>')
    environment_position = about_page.body.index('<h4><em>env variables</em></h4>')
    expect(account_position).to be < environment_position
  end

  it 'renders the shared navigation with the current section active' do
    create_account
    client = ApplicationSessionClient.new(app)
    login(client)

    {
      '/' => ['stats', '/'],
      '/history' => ['history', '/history'],
      '/api-docs' => ['api', '/api-docs'],
      '/tools' => ['tools', '/tools'],
      '/logs' => ['logs', '/logs'],
      '/about' => ['about', '/about']
    }.each do |path, (label, href)|
      response = client.get(path)

      expect(response.status).to eq(200)
      expect(response.body.scan('<div class="terminal-nav">').length).to eq(1)
      expect(response.body).to include("class=\"menu-item active\" href=\"#{href}\">#{label}</a>")
    end
  end

  it 'changes both credentials while preserving the current browser session' do
    create_account
    client = ApplicationSessionClient.new(app)
    login(client)
    account_page = client.get('/account')

    email_response = change_email(client, account_page)
    expect(email_response.status).to eq(302)
    expect(redirect_path(email_response)).to eq('/account')

    account_page = client.get('/account')
    password_response = change_password(client, account_page)

    expect(password_response.status).to eq(302)
    expect(redirect_path(password_response)).to eq('/account')
    expect(client.get('/account').body).to include('current email: new-admin@example.com')

    account_page = client.get('/account')
    logout_response = client.post('/logout', _csrf: csrf_token_for(account_page, '/logout'))
    expect(logout_response.status).to eq(302)
    relogin = login(client, email: 'new-admin@example.com', password: 'even better horse battery staple')
    expect(relogin.status).to eq(302)
  end

  it 'returns an incorrect email-change password to the account page once' do
    create_account
    client = ApplicationSessionClient.new(app)
    login(client)
    account_page = client.get('/account')
    expect(account_page.body).not_to include('you have been logged in')
    failed_change = client.post(
      '/account/change-email',
      login: 'new-admin@example.com',
      password: 'incorrect password',
      _csrf: csrf_token_for(account_page, '/account/change-email')
    )

    expect(failed_change.status).to eq(302)
    expect(redirect_path(failed_change)).to eq('/account')
    error_page = client.get('/account')
    expect(error_page.body).to include('invalid password', '<legend>change email</legend>')
    expect(error_page.body).not_to include('email changed successfully', 'back to account')
    expect(client.get('/account').body).not_to include('invalid password')
  end

  it 'returns an invalid email to the account page once' do
    create_account
    client = ApplicationSessionClient.new(app)
    login(client)
    account_page = client.get('/account')
    invalid_email = client.post(
      '/account/change-email',
      login: '',
      password: 'correct horse battery staple',
      _csrf: csrf_token_for(account_page, '/account/change-email')
    )
    expect(invalid_email.status).to eq(302)
    expect(redirect_path(invalid_email)).to eq('/account')
    error_page = client.get('/account')
    expect(error_page.body).to include('invalid email: minimum 3 characters')
    expect(client.get('/account').body).not_to include('invalid email: minimum 3 characters')
  end

  it 'shows the email-change success message once' do
    create_account
    client = ApplicationSessionClient.new(app)
    login(client)
    account_page = client.get('/account')
    response = change_email(client, account_page)

    expect(response.status).to eq(302)
    expect(redirect_path(response)).to eq('/account')
    expect(client.get('/account').body).to include('email changed successfully')
    expect(client.get('/account').body).not_to include('email changed successfully')
  end

  it 'returns an incorrect password-change password to the account page once' do
    create_account
    client = ApplicationSessionClient.new(app)
    login(client)
    account_page = client.get('/account')
    failed_change = client.post(
      '/account/change-password',
      password: 'incorrect password',
      'new-password': 'even better horse battery staple',
      'password-confirm': 'even better horse battery staple',
      _csrf: csrf_token_for(account_page, '/account/change-password')
    )

    expect(failed_change.status).to eq(302)
    expect(redirect_path(failed_change)).to eq('/account')
    error_page = client.get('/account')
    expect(error_page.body).to include('invalid password', '<legend>change password</legend>')
    expect(error_page.body).not_to include('password changed successfully', 'back to account')
    expect(client.get('/account').body).not_to include('invalid password')
  end

  it 'returns a password-confirmation mismatch to the account page once' do
    create_account
    client = ApplicationSessionClient.new(app)
    login(client)
    account_page = client.get('/account')
    mismatch = client.post(
      '/account/change-password',
      password: 'correct horse battery staple',
      'new-password': 'even better horse battery staple',
      'password-confirm': 'something else entirely',
      _csrf: csrf_token_for(account_page, '/account/change-password')
    )
    expect(mismatch.status).to eq(302)
    expect(redirect_path(mismatch)).to eq('/account')
    error_page = client.get('/account')
    expect(error_page.body).to include('passwords do not match')
    expect(client.get('/account').body).not_to include('passwords do not match')
  end

  it 'shows the password-change success message once' do
    create_account
    client = ApplicationSessionClient.new(app)
    login(client)
    account_page = client.get('/account')
    response = change_password(client, account_page)

    expect(response.status).to eq(302)
    expect(redirect_path(response)).to eq('/account')
    expect(client.get('/account').body).to include('password changed successfully')
    expect(client.get('/account').body).not_to include('password changed successfully')
  end

  it 'redirects direct account mutation GETs without rendering standalone forms' do
    create_account
    client = ApplicationSessionClient.new(app)
    login(client)

    ['/account/change-email', '/account/change-password'].each do |path|
      response = client.get(path)

      expect(response.status).to eq(302)
      expect(redirect_path(response)).to eq('/account')
      expect(response.body).not_to include('<form', 'back to account')
    end
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

  it 'does not expose OIDC completion pages when OIDC is disabled' do
    request = Rack::MockRequest.new(app)

    expect(request.get('/oidc/error').status).to eq(404)
    expect(request.get('/logged-out').status).to eq(404)
  end

  it 'allows direct web access and makes setup unavailable when web authentication is disabled' do
    ENV['WEB_AUTH_ENABLED'] = 'false'
    request = Rack::MockRequest.new(app)
    home = request.get('/')
    about = request.get('/about')

    expect(home.status).to eq(200)
    expect(home.body).not_to include('action="/logout"', 'sign out')
    expect(about.body).not_to include('href="/account"', '<h4><em>account</em></h4>')
    expect(request.get('/history').status).to eq(200)
    expect(request.get('/setup').status).to eq(404)
    expect(request.post('/setup').status).to eq(404)
    expect(request.get('/account').status).to eq(404)
    expect(request.get('/account/change-email').status).to eq(404)
    expect(request.post('/account/change-email').status).to eq(404)
    expect(request.get('/account/change-password').status).to eq(404)
    expect(request.post('/account/change-password').status).to eq(404)
    expect(DB[:accounts].count).to eq(0)
  end

  it 'hides authenticated controls after restarting with web authentication disabled' do
    create_account
    secret_path = File.join(Dir.mktmpdir, 'session_secret.txt')
    enabled_app = described_class.build(session_secret_path: secret_path)
    client = ApplicationSessionClient.new(enabled_app)
    login_page = client.get('/login')
    client.post(
      '/login',
      login: 'admin@example.com', password: 'correct horse battery staple', _csrf: csrf_token(login_page)
    )

    ENV['WEB_AUTH_ENABLED'] = 'false'
    disabled_app = described_class.build(session_secret_path: secret_path)
    client.instance_variable_set(:@request, Rack::MockRequest.new(disabled_app))
    home = client.get('/')
    about = client.get('/about')

    expect(home.status).to eq(200)
    expect(home.body).not_to include('action="/logout"', 'sign out')
    expect(about.body).not_to include('href="/account"', '<h4><em>account</em></h4>')
  end

  it 'always requires an API key independently of browser authentication' do
    issued_key = ApiKey.issue('application spec')
    request = Rack::MockRequest.new(app)

    expect(request.get('/api/stats').status).to eq(401)
    expect(request.get('/api/stats', bearer_auth(issued_key.token)).status).to eq(200)
    expect(request.get('/api/health').status).to eq(401)
    expect(request.get('/api/health', bearer_auth(issued_key.token)).status).to eq(200)

    ENV['WEB_AUTH_ENABLED'] = 'false'
    request = Rack::MockRequest.new(app)

    expect(request.get('/').status).to eq(200)
    expect(request.get('/api/stats').status).to eq(401)
    expect(request.get('/api/stats', bearer_auth(issued_key.token)).status).to eq(200)
  end

  it 'ignores removed Basic Auth configuration and rejects Basic credentials' do
    ENV['BASIC_AUTH_ENABLED'] = 'true'
    ENV['BASIC_AUTH_USER'] = 'existing-user'
    ENV['BASIC_AUTH_PASS'] = 'existing-password'
    issued_key = ApiKey.issue('application spec')
    request = Rack::MockRequest.new(app)

    expect(request.get('/api/stats').status).to eq(401)
    expect(request.get('/api/stats', 'HTTP_AUTHORIZATION' => basic_auth('wrong', 'credentials')).status).to eq(401)
    expect(request.get('/api/stats', 'HTTP_AUTHORIZATION' => basic_auth).status).to eq(401)
    expect(request.get('/api/stats', bearer_auth(issued_key.token)).status).to eq(200)
  end

  it 'routes API paths directly to Grape instead of the browser stack' do
    issued_key = ApiKey.issue('application spec')
    expect(Framework::Web).not_to receive(:call)

    response = Rack::MockRequest.new(app).get('/api/stats', bearer_auth(issued_key.token))

    expect(response.status).to eq(200)
    expect(response.headers).not_to include('set-cookie')
  end

  it 'does not accept a Rodauth browser session as API authentication' do
    create_account
    client = ApplicationSessionClient.new(app)
    login(client)

    response = client.get('/api/stats')

    expect(response.status).to eq(401)
    expect(response.headers).not_to include('set-cookie')
  end

  it 'keeps similarly named web paths out of the API stack' do
    ENV['WEB_AUTH_ENABLED'] = 'false'
    request = Rack::MockRequest.new(app)

    expect(request.get('/api').status).to eq(404)
    expect(request.get('/api/missing').status).to eq(404)
    expect(request.get('/api/stats').status).to eq(401)
    expect(request.get('/api-docs').status).to eq(200)
    expect(request.get('/api-keys').status).to eq(404)
    expect(request.get('/apiculture').status).to eq(404)
  end

  it 'consolidates API documentation and key management behind web authentication' do
    create_account
    client = ApplicationSessionClient.new(app)

    response = client.get('/api-docs')
    expect(response.status).to eq(302)
    expect(redirect_path(response)).to eq('/login')

    login(client)
    issued_key = ApiKey.issue('existing client')
    response = client.get('/api-docs')

    expect(response.status).to eq(200)
    expect(response.body).to include(
      'endpoints', '/api/health', 'api keys', 'action="/api-docs/keys"', issued_key.api_key.token_prefix
    )
    endpoints_position = response.body.index('<h4><em>api endpoints</em></h4>')
    keys_position = response.body.index('<h4><em>api keys</em></h4>')
    expect(endpoints_position).to be < keys_position
    expect(response.body.scan('href="/api-docs">api</a>').length).to eq(1)
    expect(response.body).not_to include('href="/api-keys"', '>keys</a>')
    expect(response.body).to include('<code>Authorization: Bearer qbop_...</code>')
    expect(response.body).to include('including <code>/api/health</code>', 'http basic auth is not supported')
    expect(response.body).not_to match(%r{<code[^>]*>`|`</code>})
  end

  it 'creates an API key with CSRF and displays its secret exactly once' do
    create_account
    client = ApplicationSessionClient.new(app)
    login(client)
    page = client.get('/api-docs')

    expect(client.post('/api-docs/keys', name: 'home assistant').status).to eq(403)
    expect(ApiKey.count).to eq(0)

    creation_path = '/api-docs/keys'
    creation = client.post(creation_path, name: 'home assistant', _csrf: csrf_token_for(page, creation_path))
    expect(creation.status).to eq(303)
    expect(redirect_path(creation)).to eq('/api-docs')

    secret_page = client.get(redirect_path(creation))
    token = secret_page.body[/qbop_[0-9a-f]{64}/]
    api_key = ApiKey.first

    expect(secret_page.status).to eq(200)
    expect(secret_page['cache-control']).to include('no-store')
    expect(secret_page.body).to include('copy this api key now. it will not be shown again.')
    expect(token).not_to be_nil
    expect(api_key.name).to eq('home assistant')
    expect(api_key.token_digest).to eq(Digest::SHA256.hexdigest(token))
    expect(api_key.values.values).not_to include(token)
    expect(creation['set-cookie']).not_to include(token)

    later_page = client.get('/api-docs')
    expect(later_page.body).to include("#{api_key.token_prefix}...")
    expect(later_page.body).not_to include(token)
  end

  it 'rejects empty names and escapes key names in the list' do
    ENV['WEB_AUTH_ENABLED'] = 'false'
    client = ApplicationSessionClient.new(app)
    page = client.get('/api-docs')
    creation_path = '/api-docs/keys'
    response = client.post(creation_path, name: '   ', _csrf: csrf_token_for(page, creation_path))
    error_page = client.get(redirect_path(response))

    expect(error_page.body).to include('name is required')
    expect(ApiKey.count).to eq(0)

    name = '<script>alert(1)</script>'
    response = client.post(creation_path, name: name, _csrf: csrf_token_for(error_page, creation_path))
    key_page = client.get(redirect_path(response))

    expect(key_page.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
    expect(key_page.body).not_to include(name)
  end

  it 'revokes one key with CSRF without affecting another key' do
    ENV['WEB_AUTH_ENABLED'] = 'false'
    client = ApplicationSessionClient.new(app)
    first = ApiKey.issue('first client')
    second = ApiKey.issue('second client')
    page = client.get('/api-docs')
    delete_path = "/api-docs/keys/#{first.api_key.id}/delete"

    expect(client.get(delete_path).status).to eq(404)
    expect(client.post(delete_path).status).to eq(403)
    expect(ApiKey[first.api_key.id]).not_to be_nil

    response = client.post(delete_path, _csrf: csrf_token_for(page, delete_path))
    request = Rack::MockRequest.new(app)

    expect(response.status).to eq(303)
    expect(redirect_path(response)).to eq('/api-docs')
    expect(ApiKey[first.api_key.id]).to be_nil
    expect(ApiKey[second.api_key.id]).not_to be_nil
    expect(client.get('/api-docs').body).not_to include('first client')
    expect(request.get('/api/stats', bearer_auth(first.token)).status).to eq(401)
    expect(request.get('/api/stats', bearer_auth(second.token)).status).to eq(200)
  end

  it 'does not expose the former API-key page or mutation routes' do
    ENV['WEB_AUTH_ENABLED'] = 'false'
    request = Rack::MockRequest.new(app)

    expect(request.get('/api-keys').status).to eq(404)
    expect(request.post('/api-keys').status).to eq(404)
    expect(request.post('/api-keys/1/delete').status).to eq(404)
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
