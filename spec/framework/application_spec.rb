require 'bundler/setup'
Bundler.require(:default)

require 'base64'
require 'rack/mock'
require 'tmpdir'
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

RSpec.describe Framework::Application do # rubocop:disable Metrics/BlockLength
  around do |example|
    keys = %w[BASIC_AUTH_ENABLED BASIC_AUTH_USER BASIC_AUTH_PASS]
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

  def app
    described_class.build(session_secret_path: File.join(Dir.mktmpdir, 'session_secret.txt'))
  end

  def basic_auth
    "Basic #{Base64.strict_encode64('existing-user:existing-password')}"
  end

  it 'keeps web and API routes available without authentication when Basic Auth is disabled' do
    request = Rack::MockRequest.new(app)

    expect(request.get('/').status).to eq(200)
    expect(request.get('/api/stats').status).to eq(200)
  end

  it 'keeps Basic Auth authoritative for both web and API routes' do
    ENV['BASIC_AUTH_ENABLED'] = 'true'
    ENV['BASIC_AUTH_USER'] = 'existing-user'
    ENV['BASIC_AUTH_PASS'] = 'existing-password'
    request = Rack::MockRequest.new(app)

    expect(request.get('/').status).to eq(401)
    expect(request.get('/api/stats').status).to eq(401)
    expect(request.get('/', 'HTTP_AUTHORIZATION' => basic_auth).status).to eq(200)
    expect(request.get('/api/stats', 'HTTP_AUTHORIZATION' => basic_auth).status).to eq(200)
  end

  it 'does not expose a public account-creation endpoint' do
    request = Rack::MockRequest.new(app)

    expect(request.get('/auth/create-account').status).to eq(404)
    expect(request.post('/auth/create-account').status).to eq(404)
    expect(request.get('/auth/login').body).not_to include('/auth/create-account')
  end
end
