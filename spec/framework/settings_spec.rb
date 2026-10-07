require 'bundler/setup'
Bundler.require(:default)
require 'cgi'
require 'rack/mock'
require 'stringio'
require 'uri'
require_relative '../support/database_helper'
require_relative '../support/settings_secret_helper'
SpecDatabase.reset!
require_relative '../../service/helpers'
require_relative '../../service/qbit'
require_relative '../../jobs/qbop'
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

# Exercises real sessions, route-bound CSRF tokens, and formatted HTTP access logging.
class SettingsSessionClient
  attr_reader :session, :access_log, :errors

  def initialize(app)
    @access_log = StringIO.new
    @errors = StringIO.new
    observer = lambda do |env|
      response = app.call(env)
      @session = env['rack.session'].to_hash
      @authentication = env['rodauth']
      response
    end
    @request = Rack::MockRequest.new(Rack::CommonLogger.new(observer, @access_log))
  end

  def get(path)
    record_cookie(@request.get(path, headers))
  end

  def post(path, params = {})
    record_cookie(@request.post(path, headers.merge(
                                        'CONTENT_TYPE' => 'application/x-www-form-urlencoded',
                                        input: Rack::Utils.build_query(params)
                                      )))
  end

  def token_for(path)
    CGI.unescapeHTML(@authentication.csrf_tag(path)[/name="_csrf" value="([^"]+)"/, 1])
  end

  private

  def headers
    { 'rack.errors' => @errors }.tap { |values| values['HTTP_COOKIE'] = @cookie if @cookie }
  end

  def record_cookie(response)
    @cookie = response['set-cookie'].split(';', 2).first if response['set-cookie']
    response
  end
end

RSpec.describe 'Browser Settings workflow' do # rubocop:disable Metrics/BlockLength
  include_context 'encrypted settings'

  around do |example|
    names = %w[WEB_AUTH_ENABLED LOCAL_LOGIN_ENABLED OIDC_ENABLED OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET
               OIDC_PUBLIC_URL OIDC_AUTO_REDIRECT]
    original = names.to_h { |name| [name, ENV[name]] }
    names.each { |name| ENV.delete(name) }
    example.run
  ensure
    original.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  before do
    SpecDatabase.reset!
    Framework::Authentication.rodauth.create_account(login: 'admin@example.com',
                                                     password: 'correct horse battery staple')
    @app = Framework::Application.build(session_secret_path: File.join(File.dirname(key_path), 'session_secret.txt'))
    @client = SettingsSessionClient.new(@app)
    login_page = @client.get('/login')
    token = CGI.unescapeHTML(login_page.body[/name="_csrf" value="([^"]+)"/, 1])
    @client.post('/login', login: 'admin@example.com', password: 'correct horse battery staple', _csrf: token)
  end

  def card(response, key)
    response.body[%r{<fieldset class="setting-card[^"]*" id="setting-card-#{Regexp.escape(key.to_s)}">.*?</fieldset>}m]
  end

  def token(response, path)
    form = response.body[%r{<form action="#{Regexp.escape(path)}" method="post".*?</form>}m]
    CGI.unescapeHTML(form[/name="_csrf" value="([^"]+)"/, 1])
  end

  def save(key, value)
    page = @client.get('/settings')
    path = "/settings/#{key}"
    @client.post(path, value: value, _csrf: token(page, path))
  end

  def clear(key)
    page = @client.get('/settings')
    path = "/settings/#{key}/delete"
    @client.post(path, _csrf: token(page, path))
  end

  def expect_settings_redirect(response)
    expect(response.status).to eq(303)
    expect(URI(response['location'])).to have_attributes(path: '/settings', query: nil)
    expect(response['cache-control']).to include('no-store')
  end

  def expect_settings_notice(page, key, action, restart:)
    notice = page.body[%r{<div class="terminal-alert terminal-alert-primary" role="status">.*?</div>}m]
    expect(notice).to include("#{Service::Settings.new.metadata(key).label} #{action}.")
    expect(notice.include?('Restart qbop to apply this change')).to eq(restart)
  end

  it 'uses the existing browser login and setup requirements for the page and both POST routes' do
    anonymous = SettingsSessionClient.new(@app)
    [anonymous.get('/settings'), anonymous.post('/settings/loop_freq', value: '60'),
     anonymous.post('/settings/loop_freq/delete')].each do |response|
      expect(response.status).to eq(302)
      expect(URI(response['location']).path).to eq('/login')
    end
    expect(Setting.count).to eq(0)
    DB[:account_password_hashes].delete
    DB[:accounts].delete
    expect(URI(anonymous.get('/settings')['location']).path).to eq('/setup')
  end

  it 'renders authenticated settings, navigation and six groups without importing rows or exposing auth settings' do
    page = @client.get('/settings')

    expect(page.status).to eq(200)
    expect(page['cache-control']).to include('no-store')
    expect(page.body).to include('class="menu-item active" href="/settings">settings</a>', '/css/settings.css')
    %w[Application ProtonVPN Gluetun OPNsense qBittorrent Logging].each do |group|
      expect(page.body).to include("<span>#{group}</span>")
    end
    expect(page.body.scan('id="setting-card-').size).to eq(25)
    expect(card(page, :loop_freq)).to include('<strong>Default</strong>', 'type="number"', 'value="45"', 'min="1"')
    expect(card(page, :port_source)).to include('<select', 'value="proton" selected', 'value="gluetun"')
    expect(card(page, :qbit_skip)).to include('<select', 'value="true"', 'value="false" selected')
    expect(card(page, :qbit_addr)).to include('Not configured', 'type="url"')
    expect(page.body).not_to include('WEB_AUTH_ENABLED', 'LOCAL_LOGIN_ENABLED', 'OIDC_',
                                     '/settings/opn_proton_alias_name')
    expect(Setting.count).to eq(0)
    expect(File.exist?(key_path)).to be(false)
  end

  it 'groups every setting inside native collapsible sections that are initially closed' do
    page = @client.get('/settings')
    sections = page.body.scan(%r{<details\sclass="settings-section"([^>]*)>\s*
                                 <summary\sclass="settings-section-summary">\s*<span>([^<]+)</span>
                                 .*?</summary>(.*?)</details>}mx)
    expected = {
      'Application' => %w[ui_mode loop_freq required_attempts port_source],
      'ProtonVPN' => %w[proton_gateway],
      'Gluetun' => %w[gluetun_addr gluetun_api_key gluetun_user gluetun_pass gluetun_ssl_verify],
      'OPNsense' => %w[opnsense_skip opnsense_interface_addr opnsense_api_key opnsense_api_secret
                       opnsense_alias_name opnsense_ssl_verify],
      'qBittorrent' => %w[qbit_skip qbit_addr qbit_api_key qbit_user qbit_pass qbit_ssl_verify],
      'Logging' => %w[log_lines log_reverse log_to_stdout]
    }

    expect(sections.map { |_, name, _| name }).to eq(expected.keys)
    sections.each do |attributes, name, content|
      expect(attributes).not_to include(' open')
      expect(content.scan(/id="setting-card-([^"]+)"/).flatten).to eq(expected.fetch(name))
    end
    expect(page.body).to include('<span class="settings-section-count">(5)</span>')
  end

  it 'groups settings in named fieldsets with accessible inline editors without duplicate editable values' do
    settings.set(:opnsense_alias_name, 'forwarded_port')
    page = @client.get('/settings')

    %i[loop_freq ui_mode opnsense_alias_name].each do |key|
      entry = card(page, key)
      form = entry[%r{<form action="/settings/#{key}".*?</form>}m]
      expect(entry).to match(%r{\A<fieldset[^>]*>\s*<legend>#{settings.metadata(key).label}</legend>})
      expect(entry).to include('class="setting-meta"')
      expect(form).to include('class="setting-form form-group"', 'class="setting-editor',
                              "<label for=\"setting-#{key}\" class=\"setting-label-hidden\">", '>Save</button>')
      expect(entry).not_to include('Current value:')
    end
    expect(card(page, :loop_freq)).to include('<strong>Default</strong>', 'Restart required', 'value="45"')
    expect(card(page, :ui_mode)).not_to include('Restart required')
    expect(card(page, :opnsense_alias_name)).to include('Configured in qbop', 'value="forwarded_port"',
                                                        '/settings/opnsense_alias_name/delete')
  end

  it 'shows a stored non-secret value as configured in qbop with a separate clear form' do
    settings.set(:qbit_addr, 'http://qbit:8080')

    entry = card(@client.get('/settings'), :qbit_addr)

    expect(entry).to include('Configured in qbop', 'value="http://qbit:8080"', '/settings/qbit_addr/delete')
    expect(entry).not_to include(' disabled')
  end

  { qbit_addr: ['QBIT_ADDR', 'http://environment-qbit:8080'], qbit_skip: %w[QBIT_SKIP false],
    qbit_ssl_verify: %w[QBIT_SSL_VERIFY false] }.each do |key, (name, value)|
    it "renders authoritative #{name} as read-only, including meaningful false booleans" do
      ENV[name] = value

      entry = card(@client.get('/settings'), key)

      expect(entry).to include("Managed by environment: #{name}", ' disabled')
      expect(entry).to include('Current value:') if key == :qbit_addr
      expect(entry).not_to include("/settings/#{key}/delete")
    end
  end

  it 'keeps ignorable blank placeholders editable and identifies the actual winning alias ENV' do
    ENV.update('QBIT_ADDR' => ' ', 'UI_MODE' => '', 'OPN_ALIAS_NAME' => ' ', 'OPN_PROTON_ALIAS_NAME' => 'legacy_alias')
    page = @client.get('/settings')

    %i[qbit_addr ui_mode].each do |key|
      expect(card(page, key)).not_to include('Managed by environment', ' required disabled', 'type="submit" disabled')
    end
    expect(card(page, :opnsense_alias_name)).to include('Managed by environment: OPN_PROTON_ALIAS_NAME', ' disabled')
  end

  it 'renders blank authoritative PORT_SOURCE as managed and invalid without failing the page' do
    ENV['PORT_SOURCE'] = ''

    page = @client.get('/settings')

    expect(page.status).to eq(200)
    expect(card(page, :port_source)).to include('Managed by environment: PORT_SOURCE', ' disabled',
                                                'PORT_SOURCE must be proton or gluetun')
  end

  it 'shows an inactive stored override underneath ENV without revealing that stored value' do
    settings.set(:qbit_addr, 'http://private-inactive-qbit:8080')
    ENV['QBIT_ADDR'] = 'http://environment-qbit:8080'

    entry = card(@client.get('/settings'), :qbit_addr)

    expect(entry).to include('Managed by environment: QBIT_ADDR', 'override is also stored but is currently inactive',
                             'value="http://environment-qbit:8080"', '/settings/qbit_addr/delete')
    expect(entry).not_to include('private-inactive-qbit')
  end

  it 'redacts credentials embedded in legacy ENV URLs and hides unsupported URL query material' do
    ENV['GLUETUN_ADDR'] = 'http://private-url-user:private-url-password@gluetun:8000/control'
    ENV['QBIT_ADDR'] = 'http://qbit:8080/?token=private-query-token'

    page = @client.get('/settings')

    expect(card(page, :gluetun_addr)).to include('http://***@gluetun:8000/control')
    expect(card(page, :qbit_addr)).to include('[invalid URL]')
    expect(page.body).not_to include('private-url-user', 'private-url-password', 'private-query-token')
  end

  { loop_freq: [' +0060 ', '60'], required_attempts: %w[05 5], ui_mode: [' LIGHT ', 'light'],
    log_reverse: %w[TRUE true] }.each do |key, (input, stored)|
    it "saves #{key} canonically through service validation and redirects without submitted values" do
      response = save(key, input)

      expect_settings_redirect(response)
      expect(Setting[name: key.to_s].value).to eq(stored)
      expect(response['location']).not_to include(input)
      page = @client.get('/settings')
      expect(page.body).to include("#{key.to_s.upcase} saved.")
      expect(@client.get('/settings').body).not_to include("#{key.to_s.upcase} saved.")
    end
  end

  it 'shows static validation errors after redirect and never reflects an invalid submitted value' do
    submitted = '<script>invalid-private-input</script>'

    response = save(:loop_freq, submitted)

    expect_settings_redirect(response)
    expect(Setting.count).to eq(0)
    expect(@client.get('/settings').body).to include('LOOP_FREQ must be a complete integer greater than 0.')
    expect(@client.session.inspect).not_to include(submitted, 'invalid-private-input')
    expect(@client.access_log.string).not_to include(submitted, 'invalid-private-input')
  end

  %w[unknown opn_proton_alias_name oidc_client_secret web_auth_enabled].each do |key|
    it "rejects #{key} with a safe 404 even with valid CSRF" do
      @client.get('/settings')
      path = "/settings/#{key}"
      response = @client.post(path, value: 'private-input', _csrf: @client.token_for(path))

      expect(response.status).to eq(404)
      expect(response.body).to eq('Setting not found.')
      expect(response['cache-control']).to include('no-store')
      expect(Setting.count).to eq(0)
    end
  end

  it 'enforces ENV management server-side and permits clearing only the inactive DB override' do
    settings.set(:qbit_addr, 'http://stored-qbit:8080')
    settings.set(:loop_freq, 60)
    ENV['QBIT_ADDR'] = 'http://environment-qbit:8080'

    response = save(:qbit_addr, 'http://attempted-qbit:8080')

    expect_settings_redirect(response)
    expect(Setting[name: 'qbit_addr'].value).to eq('http://stored-qbit:8080')
    expect(@client.get('/settings').body).to include('QBIT_ADDR is managed by environment and cannot be edited here.')
    expect_settings_redirect(clear(:qbit_addr))
    expect(Setting[name: 'qbit_addr']).to be_nil
    expect(Setting[name: 'loop_freq'].value).to eq('60')
    expect(Service::Settings.new.value(:qbit_addr)).to eq('http://environment-qbit:8080')
    expect(ENV['QBIT_ADDR']).to eq('http://environment-qbit:8080')
  end

  it 'clears a DB override back to its default and requires an existing row to clear' do
    settings.set(:loop_freq, 60)

    expect_settings_redirect(clear(:loop_freq))
    expect(Service::Settings.new.value(:loop_freq)).to eq(45)
    page = @client.get('/settings')
    expect(card(page, :loop_freq)).not_to include('/settings/loop_freq/delete')
    path = '/settings/loop_freq/delete'
    expect(@client.post(path, _csrf: @client.token_for(path)).status).to eq(404)
    expect(@client.get('/settings/loop_freq/delete').status).to eq(404)
  end

  it 'renders all eight DB and ENV credentials as empty password fields without reading ciphertext' do
    values = SpecSettingsSecrets::CREDENTIALS.keys.to_h { |key| [key, "database-private-#{key}"] }
    values.each { |key, value| settings.set(key, value) }
    stored = Setting.select_map(:value)
    key_material = File.read(key_path)
    File.unlink(key_path)
    expect(Service::SettingsEncryption).not_to receive(:new)
    page = @client.get('/settings')

    expect(page.status).to eq(200)
    values.each_key do |key|
      entry = card(page, key)
      field = entry[/<input id="setting-#{key}"[^>]*>/]
      expect(entry).to include('Configured in qbop')
      expect(field).to include('type="password"', 'autocomplete="new-password"')
      expect(field).not_to include('value=')
    end
    SpecSettingsSecrets::CREDENTIALS.each_value { |name, _| ENV[name] = "env-private-#{name}" }
    page = @client.get('/settings')
    SpecSettingsSecrets::CREDENTIALS.each do |key, (name, _)|
      expect(card(page, key)).to include("Managed by environment: #{name}", 'currently inactive')
    end
    expect(page.body).not_to include(*values.values, *stored, key_material, 'enc:v1:', 'env-private-')
  end

  it 'renders malformed DB secrets as configured without decrypting them' do
    Setting.create(name: 'qbit_pass', value: 'private-malformed-ciphertext')
    expect(Service::SettingsEncryption).not_to receive(:new)

    page = @client.get('/settings')

    expect(page.status).to eq(200)
    expect(card(page, :qbit_pass)).to include('Configured in qbop')
    expect(page.body).not_to include('private-malformed-ciphertext')
  end

  it 'encrypts a submitted secret, preserves spaces, and keeps HTML, flash, logs and About/API output safe' do
    value = ' new-private-qbit-password '
    response = save(:qbit_pass, value)

    expect_settings_redirect(response)
    stored = Setting[name: 'qbit_pass'].value
    expect(stored).to start_with('enc:v1:')
    expect(stored).not_to include(value)
    expect(Service::Settings.new.value(:qbit_pass)).to eq(value)
    expect(@client.session.inspect).not_to include(value, stored)
    page = @client.get('/settings')
    expect(page.body).not_to include(value, stored)
    expect(page.body).to include('QBIT_PASS saved.', 'Restart qbop to apply this change')
    expect(@client.access_log.string).not_to include(value, stored)
    expect(@client.errors.string).not_to include(value, stored)
    expect(@client.get('/about').body).to include('QBIT_PASS: ***')
    api_key = ApiKey.issue('settings compatibility test')
    about = Rack::MockRequest.new(@app).get('/api/about', 'HTTP_AUTHORIZATION' => "Bearer #{api_key.token}")
    expect(JSON.parse(about.body)['env_variables']['qbit_pass']).to eq('***')
    expect(about.body).not_to include(value, stored, 'environment_override', 'database_value_present')
  end

  ['', ' ', "submitted-private-secret\n"].each do |input|
    it 'rejects blank or invalid secret replacement without overwriting or leaking the existing credential' do
      settings.set(:qbit_pass, 'existing-private-password')
      stored = Setting[name: 'qbit_pass'].value

      response = save(:qbit_pass, input)

      expect_settings_redirect(response)
      expect(Setting[name: 'qbit_pass'].value).to eq(stored)
      expect(@client.session.inspect).not_to include('submitted-private-secret', 'existing-private-password', stored)
      page = @client.get('/settings')
      expect(page.body).to include('QBIT_PASS must be a valid, nonblank string without control characters.')
      expect(page.body).not_to include('submitted-private-secret', 'existing-private-password', stored)
      expect(@client.access_log.string).not_to include('submitted-private-secret', 'existing-private-password')
    end
  end

  it 'rejects replacement of ENV-managed secrets and clears an inactive DB secret without altering ENV auth' do
    settings.set(:gluetun_api_key, 'database-private-key')
    settings.set(:qbit_pass, 'database-private-password')
    key_material = File.read(key_path)
    ciphertext = Setting[name: 'gluetun_api_key'].value
    ENV['GLUETUN_API_KEY'] = 'environment-private-key'

    expect_settings_redirect(save(:gluetun_api_key, 'attempted-private-key'))
    expect(Setting[name: 'gluetun_api_key'].value).to eq(ciphertext)
    expect_settings_redirect(clear(:gluetun_api_key))
    expect(Setting[name: 'gluetun_api_key']).to be_nil
    expect(Service::Helpers.new.env_variables[:gluetun_api_key]).to eq('environment-private-key')
    expect(Service::Settings.new.value(:qbit_pass)).to eq('database-private-password')
    expect(File.read(key_path)).to eq(key_material)
    expect_settings_redirect(clear(:qbit_pass))
    expect(Setting.count).to eq(0)
    expect(File.read(key_path)).to eq(key_material)
  end

  it 'handles credential storage failures through PRG with a static error and no key-management details' do
    settings.set(:qbit_pass, 'existing-private-password')
    File.unlink(key_path)

    response = save(:gluetun_api_key, 'submitted-private-key')

    expect_settings_redirect(response)
    page = @client.get('/settings')
    expect(page.body).to include('Credential could not be saved.')
    expect(page.body).not_to include('submitted-private-key', 'existing-private-password', 'encryption key', key_path)
    expect(@client.session.inspect).not_to include('submitted-private-key')
    expect(File.exist?(key_path)).to be(false)
  end

  it 'escapes user-controlled ENV, DB and flash text in HTML and attributes' do
    value = '"><script>alert("xss")</script>'
    settings.set(:opnsense_alias_name, value)
    ENV['PROTON_GATEWAY'] = value
    page = @client.get('/settings')

    expect(card(page, :opnsense_alias_name)).to include(Rack::Utils.escape_html(value))
    expect(card(page, :proton_gateway)).to include(Rack::Utils.escape_html(value))
    expect(page.body).not_to include(value, '<script>alert(')
    allow_any_instance_of(Service::Settings).to receive(:set)
      .and_raise(Service::Settings::ValidationError, '<unsafe-error>')
    response = save(:loop_freq, 'invalid')
    expect_settings_redirect(response)
    page = @client.get('/settings')
    expect(page.body).to include('&lt;unsafe-error&gt;')
    expect(page.body).not_to include('<unsafe-error>')
  end

  it 'shows restart notices for job settings on save and clear, without restarting jobs or probing clients' do
    expect(Qbop).not_to receive(:perform_async)
    [Service::Gluetun, Service::Opnsense, Service::Qbit].each { |client| expect(client).not_to receive(:new) }

    expect_settings_redirect(save(:loop_freq, '60'))
    expect(@client.get('/settings').body).to include('LOOP_FREQ saved. Restart qbop to apply this change')
    expect_settings_redirect(clear(:loop_freq))
    expect(@client.get('/settings').body).to include('LOOP_FREQ cleared. Restart qbop to apply this change')
    expect_settings_redirect(save(:ui_mode, 'light'))
    page = @client.get('/settings')
    notice = page.body[%r{<div class="terminal-alert terminal-alert-primary" role="status">.*?</div>}m]
    expect(notice).to include('UI_MODE saved.')
    expect(notice).not_to include('Restart')
    expect(page.body).to include('/css/light.css')
  end

  { loop_freq: [' +0045 ', '45'], port_source: %w[proton proton],
    qbit_skip: %w[FALSE false] }.each do |key, (input, stored)|
    it "pins the unchanged #{key} default and clears it without a restart notice" do
      original = Service::Settings.new.value(key)
      expect(card(@client.get('/settings'), key)).to include('<strong>Default</strong>')

      expect_settings_redirect(save(key, input))
      expect(Setting[name: key.to_s].value).to eq(stored)
      expect(Service::Settings.new.resolve(key)).to have_attributes(value: original, source: :database)
      page = @client.get('/settings')
      expect_settings_notice(page, key, 'saved', restart: false)
      expect(card(page, key)).to include('Configured in qbop', '/delete', 'Restart required')

      expect_settings_redirect(clear(key))
      expect(Setting[name: key.to_s]).to be_nil
      expect(Service::Settings.new.resolve(key)).to have_attributes(value: original, source: :default)
      page = @client.get('/settings')
      expect_settings_notice(page, key, 'cleared', restart: false)
      expect(card(page, key)).to include('<strong>Default</strong>', 'Restart required')
      expect(card(page, key)).not_to include('/delete')
    end
  end

  it 'compares normalized numeric values when replacing an existing override' do
    settings.set(:loop_freq, 60)

    expect_settings_redirect(save(:loop_freq, ' +0060 '))

    expect(Setting[name: 'loop_freq'].value).to eq('60')
    expect_settings_notice(@client.get('/settings'), :loop_freq, 'saved', restart: false)
  end

  { opnsense_interface_addr: ['OPN_INTERFACE_ADDR', '', 'http://opnsense', true],
    opnsense_skip: ['OPN_SKIP', ' ', 'false', false] }.each do |key, (name, fallback, stored, restart)|
    it "compares the effective #{key} value when clearing to a legacy blank ENV fallback" do
      ENV[name] = fallback
      settings.set(key, stored)
      expect(Service::Settings.new.resolve(key).source).to eq(:database)

      expect_settings_redirect(clear(key))

      expect(Setting[name: key.to_s]).to be_nil
      expect(Service::Settings.new.resolve(key)).to have_attributes(value: fallback, source: :environment)
      expect(ENV[name]).to eq(fallback)
      expect_settings_notice(@client.get('/settings'), key, 'cleared', restart: restart)
    end
  end

  ['http://environment-qbit:8080', 'http://different-stored-qbit:8080'].each do |stored|
    it 'omits restart notices when clearing an inactive override leaves authoritative ENV unchanged' do
      settings.set(:qbit_addr, stored)
      ENV['QBIT_ADDR'] = 'http://environment-qbit:8080'

      expect_settings_redirect(clear(:qbit_addr))

      expect(Setting[name: 'qbit_addr']).to be_nil
      expect(Service::Settings.new.value(:qbit_addr)).to eq('http://environment-qbit:8080')
      expect(ENV['QBIT_ADDR']).to eq('http://environment-qbit:8080')
      expect_settings_notice(@client.get('/settings'), :qbit_addr, 'cleared', restart: false)
    end
  end

  { log_lines: '75', log_reverse: 'true' }.each do |key, input|
    it "omits restart notices when saving or clearing a changed dynamic #{key} value" do
      expect_settings_redirect(save(key, input))
      expect_settings_notice(@client.get('/settings'), key, 'saved', restart: false)
      expect_settings_redirect(clear(key))
      expect_settings_notice(@client.get('/settings'), key, 'cleared', restart: false)
    end
  end

  { ' existing-private-password ' => false, ' different-private-password ' => true }.each do |input, restart|
    it 'compares secret replacements without exposing current or submitted plaintext' do
      previous = ' existing-private-password '
      settings.set(:qbit_pass, previous)
      previous_ciphertext = Setting[name: 'qbit_pass'].value

      response = save(:qbit_pass, input)

      expect_settings_redirect(response)
      ciphertext = Setting[name: 'qbit_pass'].value
      expect(ciphertext).to start_with('enc:v1:')
      expect(ciphertext).not_to include(input)
      expect(Service::Settings.new.value(:qbit_pass)).to eq(input)
      page = @client.get('/settings')
      expect_settings_notice(page, :qbit_pass, 'saved', restart: restart)
      [response.body, page.body, @client.session.inspect, @client.access_log.string,
       @client.errors.string].each do |output|
        expect(output).not_to include(previous, input, previous_ciphertext, ciphertext)
      end
    end
  end

  %w[environment-private-password different-stored-private-password].each do |stored|
    it 'clears an inactive secret without decrypting it or claiming the effective ENV credential changed' do
      settings.set(:qbit_pass, stored)
      ENV['QBIT_PASS'] = 'environment-private-password'
      File.unlink(key_path)
      expect(Service::SettingsEncryption).not_to receive(:new)

      response = clear(:qbit_pass)

      expect_settings_redirect(response)
      expect(Setting[name: 'qbit_pass']).to be_nil
      expect(Service::Settings.new.value(:qbit_pass)).to eq('environment-private-password')
      expect(ENV['QBIT_PASS']).to eq('environment-private-password')
      page = @client.get('/settings')
      expect_settings_notice(page, :qbit_pass, 'cleared', restart: false)
      [response.body, page.body, @client.session.inspect, @client.access_log.string, @client.errors.string]
        .each { |output| expect(output).not_to include(stored, 'environment-private-password') }
    end
  end

  [nil, ' '].each do |fallback|
    it 'shows a restart notice when clearing a secret changes its effective value to absent or legacy blank ENV' do
      ENV['QBIT_PASS'] = fallback if fallback
      previous = 'private-password-to-clear'
      settings.set(:qbit_pass, previous)
      ciphertext = Setting[name: 'qbit_pass'].value

      response = clear(:qbit_pass)

      expect_settings_redirect(response)
      expect(Setting[name: 'qbit_pass']).to be_nil
      expect(Service::Settings.new.value(:qbit_pass)).to eq(fallback)
      expect(ENV['QBIT_PASS']).to eq(fallback)
      page = @client.get('/settings')
      expect_settings_notice(page, :qbit_pass, 'cleared', restart: true)
      [response.body, page.body, @client.session.inspect, @client.access_log.string,
       @client.errors.string].each do |output|
        expect(output).not_to include(previous, ciphertext)
      end
    end
  end

  it 'permits replacing and clearing unreadable secrets without exposing comparison failures' do
    settings.set(:qbit_pass, 'old-private-password')
    Setting[name: 'qbit_pass'].update(value: 'private-malformed-ciphertext')

    expect_settings_redirect(save(:qbit_pass, 'replacement-private-password'))
    expect(Service::Settings.new.value(:qbit_pass)).to eq('replacement-private-password')
    expect_settings_notice(@client.get('/settings'), :qbit_pass, 'saved', restart: true)
    Setting[name: 'qbit_pass'].update(value: 'private-malformed-ciphertext')
    expect_settings_redirect(clear(:qbit_pass))
    expect(Setting[name: 'qbit_pass']).to be_nil
    page = @client.get('/settings')
    expect_settings_notice(page, :qbit_pass, 'cleared', restart: true)
    [page.body, @client.session.inspect, @client.access_log.string, @client.errors.string].each do |output|
      expect(output).not_to include('old-private-password', 'replacement-private-password',
                                    'private-malformed-ciphertext', 'could not be decrypted')
    end
  end

  it 'requires valid path-bound CSRF for both mutations, including when browser authentication is disabled' do
    settings.set(:loop_freq, 60)
    page = @client.get('/settings')
    save_path = '/settings/loop_freq'
    clear_path = '/settings/loop_freq/delete'
    [[save_path, { value: '90' }], [clear_path, {}]].each do |path, params|
      [nil, 'invalid-token', token(page, '/settings/ui_mode')].each do |csrf|
        response = @client.post(path, params.merge(_csrf: csrf))
        expect(response.status).to eq(403)
        expect(response['cache-control']).to include('no-store')
        expect(Setting[name: 'loop_freq'].value).to eq('60')
      end
    end
    expect_settings_redirect(@client.post(save_path, value: '90', _csrf: token(page, save_path)))
    ENV['WEB_AUTH_ENABLED'] = 'false'
    open_app = Framework::Application.build(session_secret_path: File.join(File.dirname(key_path),
                                                                           'session_secret.txt'))
    open_client = SettingsSessionClient.new(open_app)
    open_page = open_client.get('/settings')
    expect(open_page.status).to eq(200)
    expect(open_client.post(clear_path).status).to eq(403)
    expect_settings_redirect(open_client.post(clear_path, _csrf: token(open_page, clear_path)))
    expect(Setting[name: 'loop_freq']).to be_nil
  end
end
