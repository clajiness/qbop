require 'bundler/setup'
Bundler.require(:default)

require 'cgi'
require 'json'
require 'openid_connect'
require 'rack/mock'
require 'tmpdir'
require 'uri'
require 'webmock/rspec'
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

OIDC_SPEC_ISSUER = 'https://id.example.com'.freeze
OIDC_SPEC_CLIENT_ID = 'qbop-client'.freeze
OIDC_SPEC_CLIENT_SECRET = 'super-secret'.freeze
OIDC_SPEC_PUBLIC_URL = 'https://qbop.example.com'.freeze

class OidcAuthenticationClient
  def initialize(app)
    @request = Rack::MockRequest.new(app)
  end

  attr_reader :cookie

  def get(path, headers = {})
    record_cookie(@request.get(path, request_headers.merge(headers)))
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

  def post_raw(path, content_type:, input:)
    record_cookie(
      @request.post(
        path,
        request_headers.merge('CONTENT_TYPE' => content_type, input: input)
      )
    )
  end

  private

  def request_headers
    headers = {
      'HTTPS' => 'on', 'rack.url_scheme' => 'https', 'HTTP_HOST' => 'qbop.example.com'
    }
    headers['HTTP_COOKIE'] = @cookie if @cookie
    headers
  end

  def record_cookie(response)
    if (set_cookie = response.get_header('set-cookie'))
      @cookie = set_cookie.split(';', 2).first
    end
    response
  end
end

RSpec.describe 'OpenID Connect browser authentication' do # rubocop:disable Metrics/BlockLength
  def oidc_config(overrides = {})
    Framework::AuthenticationConfig.new(
      {
        'OIDC_ENABLED' => 'true',
        'OIDC_ISSUER' => OIDC_SPEC_ISSUER,
        'OIDC_CLIENT_ID' => OIDC_SPEC_CLIENT_ID,
        'OIDC_CLIENT_SECRET' => OIDC_SPEC_CLIENT_SECRET,
        'OIDC_PUBLIC_URL' => OIDC_SPEC_PUBLIC_URL
      }.merge(overrides.transform_keys(&:to_s))
    ).validate!
  end

  def build_app(config = oidc_config)
    downstream = lambda do |env|
      auth = env.fetch('rodauth')
      state = auth.logged_in? ? "authenticated:#{auth.account![:id]}" : 'anonymous'
      [200, { 'content-type' => 'text/plain' }, [state]]
    end

    Rack::Builder.new do
      use Framework::SessionMiddleware, secret: 's' * 64, force_secure: config.force_secure_cookie?
      use Framework::Authentication, config: config
      run downstream
    end.to_app
  end

  def build_full_app(config = oidc_config)
    Framework::Application.build(
      auth_config: config,
      session_secret_path: File.join(Dir.mktmpdir, 'session_secret.txt')
    )
  end

  def create_account(email: 'admin@example.com')
    Framework::Authentication.rodauth.create_account(
      login: email, password: 'correct horse battery staple'
    )
  end

  def csrf_token_for(response, action)
    form = response.body.match(%r{<form action="#{Regexp.escape(action)}".*?</form>}m)[0]
    CGI.unescapeHTML(form.match(/name="_csrf" value="([^"]+)"/)[1])
  end

  def csrf_token(response)
    CGI.unescapeHTML(response.body.match(/name="_csrf" value="([^"]+)"/)[1])
  end

  def discovery_document(end_session_endpoint: "#{OIDC_SPEC_ISSUER}/end-session") # rubocop:disable Metrics/MethodLength
    {
      issuer: OIDC_SPEC_ISSUER,
      authorization_endpoint: "#{OIDC_SPEC_ISSUER}/authorize",
      token_endpoint: "#{OIDC_SPEC_ISSUER}/token",
      userinfo_endpoint: "#{OIDC_SPEC_ISSUER}/userinfo",
      jwks_uri: "#{OIDC_SPEC_ISSUER}/jwks",
      end_session_endpoint: end_session_endpoint,
      scopes_supported: %w[openid email],
      response_types_supported: ['code'],
      subject_types_supported: ['public'],
      id_token_signing_alg_values_supported: ['RS256'],
      token_endpoint_auth_methods_supported: %w[client_secret_basic client_secret_post]
    }.compact
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def stub_provider(claims: {}, signing_key: @signing_key, signing_algorithm: :RS256,
                    end_session_endpoint: "#{OIDC_SPEC_ISSUER}/end-session", include_id_token: true)
    stub_request(:get, "#{OIDC_SPEC_ISSUER}/.well-known/openid-configuration")
      .to_return(
        status: 200, headers: { 'content-type' => 'application/json' },
        body: JSON.generate(discovery_document(end_session_endpoint: end_session_endpoint))
      )
    public_jwk = JSON::JWK.new(@signing_key.public_key)
    stub_request(:get, "#{OIDC_SPEC_ISSUER}/jwks")
      .to_return(status: 200, headers: { 'content-type' => 'application/json' },
                 body: JSON.generate(keys: [public_jwk.to_h]))

    stub_request(:post, "#{OIDC_SPEC_ISSUER}/token").to_return do |request|
      @token_request_params = URI.decode_www_form(request.body).to_h
      token_claims = {
        iss: OIDC_SPEC_ISSUER,
        aud: OIDC_SPEC_CLIENT_ID,
        sub: 'administrator-subject',
        nonce: @authorization_params.fetch('nonce'),
        email: 'admin@example.com',
        email_verified: true,
        iat: Time.now.to_i,
        exp: Time.now.to_i + 300
      }.merge(claims)
      body = {
        access_token: 'transient-access-token', token_type: 'Bearer', expires_in: 300
      }
      if include_id_token
        jwt = JSON::JWT.new(token_claims)
        @issued_id_token = if signing_algorithm == :none
                             jwt.to_s
                           else
                             jwt.sign(JSON::JWK.new(signing_key), signing_algorithm).to_s
                           end
        body[:id_token] = @issued_id_token
      end
      { status: 200, headers: { 'content-type' => 'application/json' }, body: JSON.generate(body) }
    end

    stub_request(:get, "#{OIDC_SPEC_ISSUER}/userinfo")
      .to_return(status: 200, headers: { 'content-type' => 'application/json' },
                 body: JSON.generate(sub: 'administrator-subject', email: 'admin@example.com',
                                     email_verified: true))
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def begin_authorization(client = @client)
    login_page = client.get('/login')
    csrf = csrf_token_for(login_page, Framework::Authentication::OIDC_REQUEST_PATH)
    response = client.post(Framework::Authentication::OIDC_REQUEST_PATH, _csrf: csrf)
    raise "OIDC request failed with #{response.status}: #{response.body}" unless response['location']

    @authorization_params = URI.decode_www_form(URI(response['location']).query).to_h
    response
  end

  def complete_authorization(client = @client, state: @authorization_params.fetch('state'), callback_params: {})
    client.get(
      "#{Framework::AuthenticationConfig::OIDC_CALLBACK_PATH}?#{URI.encode_www_form(
        { code: 'code-123', state: state }.merge(callback_params)
      )}"
    )
  end

  before do
    SpecDatabase.reset!
    @signing_key = OpenSSL::PKey::RSA.generate(2048)
    @client = OidcAuthenticationClient.new(build_app)
    stub_provider
  end

  it 'uses POST plus Rodauth CSRF and starts code flow with state, nonce, and PKCE S256' do
    create_account

    expect(@client.get(Framework::Authentication::OIDC_REQUEST_PATH).status).not_to eq(302)
    expect(@client.post(Framework::Authentication::OIDC_REQUEST_PATH).status).to eq(403)

    response = begin_authorization

    expect(response.status).to eq(302)
    expect(URI(response['location']).host).to eq('id.example.com')
    expect(@authorization_params).to include(
      'client_id' => OIDC_SPEC_CLIENT_ID,
      'redirect_uri' => "#{OIDC_SPEC_PUBLIC_URL}#{Framework::AuthenticationConfig::OIDC_CALLBACK_PATH}",
      'response_type' => 'code',
      'code_challenge_method' => 'S256'
    )
    expect(@authorization_params.fetch('scope').split).to contain_exactly('openid', 'email')
    expect(@authorization_params.fetch('state')).not_to be_empty
    expect(@authorization_params.fetch('nonce')).not_to be_empty
    expect(@authorization_params.fetch('code_challenge')).not_to be_empty
  end

  it 'verifies a signed response, links the existing account, and reuses the exact identity' do
    create_account
    account_id = DB[:accounts].get(:id)
    begin_authorization
    pre_login_cookie = @client.cookie
    response = complete_authorization

    expect(response.status).to eq(302)
    expect(response['location']).to eq('/')
    expect(@client.cookie).not_to eq(pre_login_cookie)
    expect(response['set-cookie']).to include('secure', 'httponly', 'samesite=lax')
    expect(response['set-cookie'].bytesize).to be < 4096
    expect(@client.get('/auth-state').body).to eq("authenticated:#{account_id}")
    expect(DB[:account_oidc_identities].all).to contain_exactly(
      include(account_id: account_id, issuer: OIDC_SPEC_ISSUER, subject: 'administrator-subject')
    )
    verifier = @token_request_params.fetch('code_verifier')
    expected_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    expect(expected_challenge).to eq(@authorization_params.fetch('code_challenge'))
    expect(DB.schema(:account_oidc_identities).map(&:first)).not_to include(
      :access_token, :refresh_token, :id_token
    )

    second_client = OidcAuthenticationClient.new(build_app)
    begin_authorization(second_client)
    complete_authorization(second_client)
    expect(DB[:account_oidc_identities].count).to eq(1)
    expect(second_client.get('/auth-state').body).to eq("authenticated:#{account_id}")
  end

  it 'continues using a linked subject after provider and local email changes' do
    create_account
    account_id = DB[:accounts].get(:id)
    begin_authorization
    complete_authorization
    DB[:accounts].where(id: account_id).update(email: 'new-local-email@example.com')

    stub_provider(claims: { email: 'changed-at-provider@example.com', email_verified: false })
    subsequent_client = OidcAuthenticationClient.new(build_app)
    begin_authorization(subsequent_client)
    response = complete_authorization(subsequent_client)

    expect(response.status).to eq(302)
    expect(subsequent_client.get('/auth-state').body).to eq("authenticated:#{account_id}")
    expect(DB[:account_oidc_identities].count).to eq(1)
  end

  it 'refuses to replace an issuer link when a different subject has the matching email' do
    create_account
    begin_authorization
    complete_authorization

    stub_provider(claims: { sub: 'replacement-subject' })
    replacement_client = OidcAuthenticationClient.new(build_app)
    begin_authorization(replacement_client)
    response = complete_authorization(replacement_client)

    expect(response.status).to eq(302)
    expect(URI(response['location']).path).to eq('/oidc/error')
    expect(replacement_client.get('/auth-state').body).to eq('anonymous')
    expect(DB[:account_oidc_identities].all).to contain_exactly(include(subject: 'administrator-subject'))
  end

  it 'does not create an account and redirects an unprovisioned installation to setup' do
    response = @client.get('/login')

    expect(response.status).to eq(302)
    expect(URI(response['location']).path).to eq('/setup')
    expect(@client.post(Framework::Authentication::OIDC_REQUEST_PATH).status).to eq(302)
    expect(DB[:accounts].count).to eq(0)
    expect(a_request(:get, "#{OIDC_SPEC_ISSUER}/.well-known/openid-configuration")).not_to have_been_made
  end

  it 'rejects a first link when the provider email is absent, unverified, or different' do
    create_account
    invalid_claims = [
      { email: nil, email_verified: true },
      { email: 'admin@example.com', email_verified: false },
      { email: 'admin@example.com', email_verified: 'true' },
      { email: 'admin@example.com', email_verified: 1 },
      { email: 'other@example.com', email_verified: true }
    ]

    invalid_claims.each do |claims|
      SpecDatabase.reset!
      create_account
      stub_provider(claims: claims)
      client = OidcAuthenticationClient.new(build_app)
      begin_authorization(client)
      response = complete_authorization(client)

      expect(response.status).to eq(302)
      expect(URI(response['location']).path).to eq('/oidc/error')
      expect(client.get('/auth-state').body).to eq('anonymous')
      expect(DB[:account_oidc_identities].count).to eq(0)
      expect(DB[:accounts].count).to eq(1)
    end
  end

  it 'rejects invalid state before exchanging the authorization code' do
    create_account
    begin_authorization

    response = complete_authorization(state: 'attacker-state')

    expect(response.status).to eq(302)
    expect(URI(response['location']).path).to eq('/oidc/error')
    expect(a_request(:post, "#{OIDC_SPEC_ISSUER}/token")).not_to have_been_made
    expect(@client.get('/auth-state').body).to eq('anonymous')
  end

  it 'does not let callback parameters override the session nonce, PKCE verifier, or redirect URI' do
    create_account
    stub_provider(claims: { nonce: 'attacker-nonce' })
    begin_authorization

    response = complete_authorization(
      callback_params: {
        nonce: 'attacker-nonce', code_verifier: 'attacker-verifier',
        redirect_uri: 'https://attacker.example/callback'
      }
    )

    expect(response.status).to eq(302)
    expect(URI(response['location']).path).to eq('/oidc/error')
    expect(@token_request_params.fetch('code_verifier')).not_to eq('attacker-verifier')
    expect(@token_request_params.fetch('redirect_uri')).to eq(
      "#{OIDC_SPEC_PUBLIC_URL}#{Framework::AuthenticationConfig::OIDC_CALLBACK_PATH}"
    )
    expect(@client.get('/auth-state').body).to eq('anonymous')
    expect(DB[:account_oidc_identities].count).to eq(0)
  end

  it 'rejects insecure or credentialed endpoints from discovery metadata' do
    create_account
    unsafe_documents = [
      discovery_document.merge(authorization_endpoint: 'http://id.example.com/authorize'),
      discovery_document.merge(token_endpoint: 'http://127.0.0.1/internal'),
      discovery_document.merge(jwks_uri: 'https://user@id.example.com/jwks'),
      discovery_document.merge(userinfo_endpoint: 'https://id.example.com/userinfo#fragment')
    ]

    unsafe_documents.each do |document|
      stub_request(:get, "#{OIDC_SPEC_ISSUER}/.well-known/openid-configuration").to_return(
        status: 200, headers: { 'content-type' => 'application/json' }, body: JSON.generate(document)
      )
      client = OidcAuthenticationClient.new(build_app)
      login_page = client.get('/login')
      csrf = csrf_token_for(login_page, Framework::Authentication::OIDC_REQUEST_PATH)

      response = client.post(Framework::Authentication::OIDC_REQUEST_PATH, _csrf: csrf)

      expect(response.status).to eq(302)
      expect(URI(response['location']).path).to eq('/oidc/error')
    end
  end

  it 'does not follow provider-discovery redirects, including HTTPS-to-HTTP downgrades' do
    create_account
    downgrade_url = 'http://id.example.com/.well-known/openid-configuration'
    stub_request(:get, "#{OIDC_SPEC_ISSUER}/.well-known/openid-configuration").to_return(
      status: 302, headers: { 'location' => downgrade_url }
    )
    stub_request(:get, downgrade_url).to_return(
      status: 200, headers: { 'content-type' => 'application/json' },
      body: JSON.generate(discovery_document)
    )
    login_page = @client.get('/login')
    csrf = csrf_token_for(login_page, Framework::Authentication::OIDC_REQUEST_PATH)

    response = @client.post(Framework::Authentication::OIDC_REQUEST_PATH, _csrf: csrf)

    expect(response.status).to eq(302)
    expect(URI(response['location']).path).to eq('/oidc/error')
    expect(a_request(:get, downgrade_url)).not_to have_been_made
  end

  it 'rejects an oversized discovery document before using its endpoints' do
    create_account
    document = discovery_document.merge(unused_padding: 'x' * Framework::OidcProviderMetadata::MAX_DOCUMENT_BYTES)
    stub_request(:get, "#{OIDC_SPEC_ISSUER}/.well-known/openid-configuration").to_return(
      status: 200, headers: { 'content-type' => 'application/json' }, body: JSON.generate(document)
    )
    login_page = @client.get('/login')
    csrf = csrf_token_for(login_page, Framework::Authentication::OIDC_REQUEST_PATH)

    response = @client.post(Framework::Authentication::OIDC_REQUEST_PATH, _csrf: csrf)

    expect(response.status).to eq(302)
    expect(URI(response['location']).path).to eq('/oidc/error')
    expect(a_request(:get, "#{OIDC_SPEC_ISSUER}/jwks")).not_to have_been_made
  end

  it 'uses certificate verification and bounded timeouts for OIDC HTTP clients' do
    [SWD.http_client, WebFinger.http_client, OpenIDConnect.http_client, Rack::OAuth2.http_client].each do |client|
      expect(client.ssl.verify).to be(true)
      expect(client.options.open_timeout).to eq(Framework::OidcHttpConfiguration::OPEN_TIMEOUT)
      expect(client.options.timeout).to eq(Framework::OidcHttpConfiguration::REQUEST_TIMEOUT)
    end
  end

  it 'fails closed for authorization denial and a malformed callback' do
    create_account

    begin_authorization
    denial = @client.get(
      "#{Framework::AuthenticationConfig::OIDC_CALLBACK_PATH}?#{URI.encode_www_form(
        error: 'access_denied', error_description: 'provider denied access',
        state: @authorization_params.fetch('state')
      )}"
    )
    expect(denial.status).to eq(302)
    expect(URI(denial['location']).path).to eq('/oidc/error')

    malformed_client = OidcAuthenticationClient.new(build_app)
    begin_authorization(malformed_client)
    malformed = malformed_client.get(
      "#{Framework::AuthenticationConfig::OIDC_CALLBACK_PATH}?#{URI.encode_www_form(
        state: @authorization_params.fetch('state')
      )}"
    )
    expect(malformed.status).to eq(302)
    expect(URI(malformed['location']).path).to eq('/oidc/error')
    expect(DB[:account_oidc_identities].count).to eq(0)
  end

  it 'turns provider discovery failures into a deliberate retry page redirect' do
    create_account
    stub_request(:get, "#{OIDC_SPEC_ISSUER}/.well-known/openid-configuration").to_raise(SocketError)
    login_page = @client.get('/login')
    csrf = csrf_token_for(login_page, Framework::Authentication::OIDC_REQUEST_PATH)

    response = @client.post(Framework::Authentication::OIDC_REQUEST_PATH, _csrf: csrf)

    expect(response.status).to eq(302)
    expect(URI(response['location']).path).to eq('/oidc/error')
    expect(DB[:account_oidc_identities].count).to eq(0)
  end

  it 'rejects a response signed by a key outside the discovered JWKS' do
    create_account
    attacker_key = OpenSSL::PKey::RSA.generate(2048)
    stub_provider(signing_key: attacker_key)
    # Keep the provider JWKS pinned to the trusted key.
    trusted_jwk = JSON::JWK.new(@signing_key.public_key)
    stub_request(:get, "#{OIDC_SPEC_ISSUER}/jwks").to_return(
      status: 200, headers: { 'content-type' => 'application/json' },
      body: JSON.generate(keys: [trusted_jwk.to_h])
    )
    begin_authorization

    response = complete_authorization

    expect(response.status).to eq(302)
    expect(URI(response['location']).path).to eq('/oidc/error')
    expect(DB[:account_oidc_identities].count).to eq(0)
    expect(@client.get('/auth-state').body).to eq('anonymous')
  end

  it 'rejects an unsigned ID token' do
    create_account
    stub_provider(signing_algorithm: :none)
    begin_authorization

    response = complete_authorization

    expect(response.status).to eq(302)
    expect(URI(response['location']).path).to eq('/oidc/error')
    expect(DB[:account_oidc_identities].count).to eq(0)
    expect(@client.get('/auth-state').body).to eq('anonymous')
  end

  it 'rejects issuer, audience, nonce, expiry, and missing-ID-token failures' do
    create_account
    invalid_responses = [
      [{ iss: 'https://attacker.example.com' }, true],
      [{ aud: 'different-client' }, true],
      [{ aud: [OIDC_SPEC_CLIENT_ID, 'other-client'] }, true],
      [{ aud: [OIDC_SPEC_CLIENT_ID, 'other-client'], azp: 'other-client' }, true],
      [{ azp: 'other-client' }, true],
      [{ sub: ' ' }, true],
      [{ sub: 123 }, true],
      [{ nonce: 'different-nonce' }, true],
      [{ exp: Time.now.to_i - 60 }, true],
      [{}, false]
    ]

    invalid_responses.each do |claims, include_id_token|
      stub_provider(claims: claims, include_id_token: include_id_token)
      client = OidcAuthenticationClient.new(build_app)
      begin_authorization(client)
      response = complete_authorization(client)

      expect(response.status).to eq(302)
      expect(URI(response['location']).path).to eq('/oidc/error')
      expect(client.get('/auth-state').body).to eq('anonymous')
      expect(DB[:account_oidc_identities].count).to eq(0)
    end
  end

  it 'rejects an oversized ID token before session storage without exposing it' do
    create_account
    stub_provider(claims: { padding: 'x' * 2_000 })
    begin_authorization

    response = complete_authorization
    error_page = @client.get(URI(response['location']).path)

    expect(response.status).to eq(302)
    expect(URI(response['location']).path).to eq('/oidc/error')
    expect(error_page.body).not_to include(@issued_id_token)
    expect(@client.get('/auth-state').body).to eq('anonymous')
    expect(DB[:account_oidc_identities].count).to eq(0)
  end

  it 'clears the local session before RP-initiated logout with a fixed callback' do
    create_account
    account_id = DB[:accounts].get(:id)
    begin_authorization
    complete_authorization
    logout_page = @client.get('/logout')
    response = @client.post('/logout', _csrf: csrf_token(logout_page))
    location = URI(response['location'])
    params = URI.decode_www_form(location.query).to_h

    expect(response.status).to eq(302)
    expect("#{location.scheme}://#{location.host}#{location.path}").to eq("#{OIDC_SPEC_ISSUER}/end-session")
    expect(params.fetch('id_token_hint')).to match(/\A[^.]+\.[^.]+\.[^.]+\z/)
    expect(params.fetch('post_logout_redirect_uri')).to eq("#{OIDC_SPEC_PUBLIC_URL}/logged-out")
    expect(@client.get('/auth-state').body).to eq('anonymous')
    expect(DB[:account_oidc_identities].get(:account_id)).to eq(account_id)
  end

  it 'falls back to the local signed-out page when discovery has no logout endpoint' do
    create_account
    stub_provider(end_session_endpoint: nil)
    begin_authorization
    complete_authorization
    logout_page = @client.get('/logout')

    response = @client.post('/logout', _csrf: csrf_token(logout_page))

    expect(response.status).to eq(302)
    expect(URI(response['location']).path).to eq('/logged-out')
    expect(@client.get('/auth-state').body).to eq('anonymous')
  end

  it 'can hide the local password form or auto-submit the OIDC POST form' do
    create_account
    oidc_only = OidcAuthenticationClient.new(build_app(oidc_config(LOCAL_LOGIN_ENABLED: 'false')))
    oidc_only_page = oidc_only.get('/login')

    expect(oidc_only_page.body).to include('sign in with OpenID Connect')
    expect(oidc_only_page.body).not_to include('name="login"', 'name="password"')
    expect(oidc_only.post('/login').status).to eq(404)
    begin_authorization(oidc_only)
    expect(complete_authorization(oidc_only).status).to eq(302)
    expect(oidc_only.get('/auth-state').body).to match(/\Aauthenticated:\d+\z/)

    automatic = OidcAuthenticationClient.new(
      build_app(oidc_config(OIDC_AUTO_REDIRECT: 'true', LOCAL_LOGIN_ENABLED: 'false'))
    )
    automatic_page = automatic.get('/login')
    expect(automatic_page.body).to include("document.getElementById('oidc-login-form').submit()")
    expect(automatic_page.body).not_to include('name="login"', 'name="password"')

    recovery = OidcAuthenticationClient.new(build_app(oidc_config(OIDC_AUTO_REDIRECT: 'true')))
    recovery_page = recovery.get('/login')
    expect(recovery_page.body).not_to include("document.getElementById('oidc-login-form').submit()")
    expect(recovery_page.body).to include('name="login"', 'name="password"')
  end

  it 'invalidates OIDC sessions after OIDC is disabled or the configured issuer changes' do
    create_account
    begin_authorization
    complete_authorization
    expect(@client.get('/auth-state').body).to match(/\Aauthenticated:\d+\z/)

    disabled = oidc_config(OIDC_ENABLED: 'false')
    @client.instance_variable_set(:@request, Rack::MockRequest.new(build_app(disabled)))
    expect(@client.get('/auth-state')['location']).to eq('/login')
    expect(@client.get('/auth-state').body).to eq('anonymous')

    # Repeat with a fresh OIDC login and a different configured issuer.
    @client = OidcAuthenticationClient.new(build_app)
    begin_authorization
    complete_authorization
    changed = oidc_config(OIDC_ISSUER: 'https://replacement-id.example.com')
    @client.instance_variable_set(:@request, Rack::MockRequest.new(build_app(changed)))
    expect(@client.get('/auth-state')['location']).to eq('/login')
    expect(@client.get('/auth-state').body).to eq('anonymous')
  end

  it 'invalidates an existing password session when local login is disabled' do
    create_account
    client = OidcAuthenticationClient.new(build_app(oidc_config(OIDC_ENABLED: 'false')))
    login_page = client.get('/login')
    client.post(
      '/login', login: 'admin@example.com', password: 'correct horse battery staple',
                _csrf: csrf_token(login_page)
    )
    expect(client.get('/auth-state').body).to match(/\Aauthenticated:\d+\z/)

    oidc_only_app = build_app(oidc_config(LOCAL_LOGIN_ENABLED: 'false'))
    client.instance_variable_set(:@request, Rack::MockRequest.new(oidc_only_app))

    expect(client.get('/auth-state')['location']).to eq('/login')
    expect(client.get('/auth-state').body).to eq('anonymous')
  end

  it 'keeps every direct local-password route variant unable to authenticate when disabled' do
    create_account
    client = OidcAuthenticationClient.new(build_app(oidc_config(LOCAL_LOGIN_ENABLED: 'false')))
    credentials = {
      login: 'admin@example.com', password: 'correct horse battery staple'
    }

    expect(client.post('/login', credentials).status).to eq(404)
    expect(client.post('/login?return_to=%2F', credentials).status).to eq(404)
    expect(client.post_raw('/login', content_type: 'application/json', input: JSON.generate(credentials)).status)
      .to eq(404)

    ['/login/', '//login', '/%6Cogin', '/login%2F'].each do |path|
      client.post(path, credentials)
      expect(client.get('/auth-state').body).to eq('anonymous')
    end
  end

  it 'keeps setup available when local password login is disabled' do
    client = OidcAuthenticationClient.new(build_app(oidc_config(LOCAL_LOGIN_ENABLED: 'false')))

    expect(client.get('/setup').status).to eq(200)
  end

  it 'keeps setup, failure, and logged-out pages out of auto-redirect loops' do
    create_account
    config = oidc_config(OIDC_AUTO_REDIRECT: 'true', LOCAL_LOGIN_ENABLED: 'false')
    client = OidcAuthenticationClient.new(build_full_app(config))

    begin_authorization(client)
    failure = client.get(
      "#{Framework::AuthenticationConfig::OIDC_CALLBACK_PATH}?#{URI.encode_www_form(
        error: 'access_denied', error_description: "unsafe #{OIDC_SPEC_CLIENT_SECRET}",
        state: @authorization_params.fetch('state')
      )}"
    )
    error_page = client.get(URI(failure['location']).path)
    logged_out_page = client.get('/logged-out')

    expect(error_page.status).to eq(200)
    expect(error_page.body).to include(Framework::Authentication::OIDC_FAILURE_MESSAGE)
    expect(error_page.body).not_to include(
      "document.getElementById('oidc-login-form').submit()", OIDC_SPEC_CLIENT_SECRET
    )
    expect(logged_out_page.status).to eq(200)
    expect(logged_out_page.body).to include('You have been logged out.')
    expect(logged_out_page.body).not_to include("document.getElementById('oidc-login-form').submit()")

    SpecDatabase.reset!
    setup_client = OidcAuthenticationClient.new(build_full_app(config))
    expect(setup_client.get('/setup').status).to eq(200)
  end

  it 'does not let an OIDC browser session authenticate API requests' do
    %w[proton opnsense qbit].each do |name|
      source = Source.create(name: name)
      Stat.create(source_id: source.id, current_port: 12_345, same_port: 60, last_checked: Time.now)
    end
    create_account
    client = OidcAuthenticationClient.new(build_full_app)
    begin_authorization(client)
    expect(complete_authorization(client).status).to eq(302)
    issued_key = ApiKey.issue('OIDC isolation spec')

    expect(client.get('/about').status).to eq(200)
    expect(client.get('/about').body).to include('OIDC_CLIENT_SECRET: ***')
    expect(client.get('/about').body).not_to include(OIDC_SPEC_CLIENT_SECRET)
    expect(client.get('/account').status).to eq(200)

    api_paths = [
      '/api/stats', '/api/tools/pubkey?private-key=test', '/api/tools/public-ip?service=invalid',
      '/api/logs', '/api/history', '/api/about', '/api/health', '/api/notifications'
    ]
    api_paths.each do |path|
      expect(client.get(path).status).to eq(401)
      expect(client.get(path, 'HTTP_AUTHORIZATION' => 'Bearer malformed').status).to eq(401)
      expect(client.get(path, 'HTTP_AUTHORIZATION' => 'Bearer transient-access-token').status).to eq(401)
      expect(client.get(path, 'HTTP_AUTHORIZATION' => "Bearer #{issued_key.token}").status).to be_between(200, 299)
    end
  end
end
