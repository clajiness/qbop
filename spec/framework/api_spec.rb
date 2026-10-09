require 'bundler/setup'
Bundler.require(:default)

require 'base64'
require 'rack/mock'
require_relative '../support/database_helper'
require_relative '../support/settings_secret_helper'
require_relative '../../service/helpers'
require_relative '../../framework/uptime'
require_relative '../../framework/api'

SpecDatabase.reset!

RSpec.describe Framework::API do # rubocop:disable Metrics/BlockLength
  def app
    described_class
  end

  def response_json(response)
    JSON.parse(response.body)
  end

  def api_get(path, token: @api_token, scheme: 'Bearer')
    headers = token ? { 'HTTP_AUTHORIZATION' => "#{scheme} #{token}" } : {}
    Rack::MockRequest.new(app).get(path, headers)
  end

  def api_post(path, body, token: @api_token, scheme: 'Bearer')
    headers = token ? { 'HTTP_AUTHORIZATION' => "#{scheme} #{token}" } : {}
    Rack::MockRequest.new(app).post(
      path,
      headers.merge('CONTENT_TYPE' => 'application/json', input: body.to_json)
    )
  end

  around do |example|
    env_keys = %w[OPN_SKIP QBIT_SKIP VERSION COMMIT_SHA BUILD_DATE LOOP_FREQ PROTON_GATEWAY PORT_SOURCE GLUETUN_API_KEY
                  GLUETUN_ADDR GLUETUN_USER GLUETUN_PASS OPN_ALIAS_NAME OPN_PROTON_ALIAS_NAME
                  UI_MODE REQUIRED_ATTEMPTS LOG_LINES LOG_REVERSE LOG_TO_STDOUT GLUETUN_SSL_VERIFY
                  OPN_INTERFACE_ADDR OPN_SSL_VERIFY QBIT_ADDR QBIT_SSL_VERIFY]
    original_env = env_keys.to_h { |key| [key, ENV[key]] }

    env_keys.each { |key| ENV.delete(key) }
    example.run
  ensure
    env_keys.each { |key| original_env[key].nil? ? ENV.delete(key) : ENV[key] = original_env[key] }
  end

  before do
    SpecDatabase.reset!
    %w[proton opnsense qbit].each do |name|
      source = Source.create(name: name)
      Stat.create(
        source_id: source.id,
        current_port: 12_345,
        same_port: 60,
        last_checked: Time.now,
        updated_at: Time.now
      )
    end
    issued_key = ApiKey.issue('api spec')
    @api_key = issued_key.api_key
    @api_token = issued_key.token
  end

  context 'encrypted database credentials' do # rubocop:disable Metrics/BlockLength
    include_context 'encrypted settings'

    it 'checks the disabled WireGuard integration without resolving unrelated unreadable credentials' do
      settings.set(:opnsense_skip, true)
      Setting.create(name: 'qbit_pass', value: 'enc:v1:unreadable-credential')
      expect(Service::SettingsEncryption).not_to receive(:new)
      expect(Service::Opnsense).not_to receive(:new)

      [api_get('/api/tools/wireguard-targets'), api_post('/api/tools/wireguard-import', {})].each do |response|
        expect(response.status).to eq(503)
        expect(response_json(response)).to eq('error' => described_class::WIREGUARD_IMPORT_UNAVAILABLE)
      end
      expect(api_get('/api/tools/wireguard-targets', token: nil).status).to eq(401)
      expect(api_post('/api/tools/wireguard-import', {}, token: nil).status).to eq(401)
      expect(Dir.children(File.dirname(key_path))).to be_empty
    end

    it 'never exposes DB credentials, ciphertext, or key material through the existing about fields' do
      values = SpecSettingsSecrets::CREDENTIALS.keys.to_h { |key| [key, "database-private-#{key}"] }
      values.each { |key, value| settings.set(key, value) }

      response = api_get('/api/about')

      expect(response.status).to eq(200)
      expect(response_json(response)['env_variables']).to include(
        'gluetun_api_key' => '***', 'gluetun_user' => '***', 'gluetun_pass' => '***',
        'opn_api_key' => '***', 'opn_api_secret' => '***', 'qbit_api_key' => '***', 'qbit_pass' => '***',
        'qbit_user' => nil
      )
      forbidden = values.values + Setting.select_map(:value) + [File.read(key_path)]
      expect(response.body).not_to include(*forbidden, 'enc:v1:', 'environment_override', '"secret"')
    end

    it 'retains the historical raw ENV username field without revealing a DB username' do
      settings.set(:qbit_user, 'database-private-username')
      ENV['QBIT_USER'] = 'legacy-visible-env-user'

      response = api_get('/api/about')

      expect(response_json(response)['env_variables']['qbit_user']).to eq('legacy-visible-env-user')
      expect(response.body).not_to include('database-private-username')
      ENV['QBIT_USER'] = ''
      expect(response_json(api_get('/api/about'))['env_variables']['qbit_user']).to eq('')
    end

    context 'diagnostics with unreadable credentials' do # rubocop:disable Metrics/BlockLength
      %i[malformed missing_key corrupt_key].each do |failure| # rubocop:disable Metrics/BlockLength
        it "preserves About and log responses without decrypting a #{failure} credential" do # rubocop:disable Metrics/BlockLength
          settings.set(:gluetun_api_key, 'private-diagnostic-credential')
          settings.set(:loop_freq, 30)
          settings.set(:log_lines, 2)
          settings.set(:log_reverse, true)
          ENV.update('UI_MODE' => 'LiGhT', 'REQUIRED_ATTEMPTS' => '5abc', 'LOG_LINES' => '',
                     'LOG_REVERSE' => ' ', 'OPN_SSL_VERIFY' => 'TRUE', 'QBIT_ADDR' => '')
          expected_about = response_json(api_get('/api/about'))['env_variables']
          forbidden = ['private-diagnostic-credential', Setting[name: 'gluetun_api_key'].value, File.read(key_path)]
          case failure
          when :malformed
            Setting[name: 'gluetun_api_key'].update(value: 'enc:v1:private-malformed-diagnostic-ciphertext')
          when :missing_key then File.unlink(key_path)
          when :corrupt_key then File.write(key_path, 'private-corrupt-diagnostic-key')
          end
          forbidden += ['enc:v1:', 'private-malformed-diagnostic-ciphertext', 'private-corrupt-diagnostic-key']
          allow(Service::SettingsEncryption).to receive(:new).and_call_original
          log_entries = [" first \n", " middle \n", " newest \n"]
          allow(File).to receive(:foreach).with('log/qbop.log').and_return(log_entries.each)

          about = api_get('/api/about')
          expect(about.status).to eq(200)
          expect(response_json(about)['env_variables']).to eq(expected_about)
          expect(about.body).not_to include(*forbidden)
          {
            '/api/logs' => %w[newest middle],
            '/api/logs?lines=3&direction=asc' => %w[first middle newest],
            '/api/logs?lines=0&direction=invalid' => %w[newest middle]
          }.each do |path, lines|
            response = api_get(path)
            expect(response.status).to eq(200)
            expect(response_json(response)).to eq('log_lines' => lines)
            expect(response.body).not_to include(*forbidden)
          end
          %w[/api/about /api/logs].each do |path|
            expect(api_get(path, token: nil).status).to eq(401)
          end
          expect(Service::SettingsEncryption).not_to have_received(:new)

          expect { Service::Gluetun.new(Service::Helpers.new.env_variables) }
            .to raise_error(Service::Settings::ConfigurationError) do |error|
              expect(error.cause).to be_nil
              expect(error.full_message).not_to include(*forbidden)
            end
        end
      end
    end
  end

  it 'preserves ENV-backed about fields while reporting historically effective fields and masking credentials' do
    settings = Service::Settings.new
    { ui_mode: 'light', loop_freq: 30, required_attempts: 5, proton_gateway: '10.7.0.1',
      log_lines: 75, log_reverse: true, log_to_stdout: true, gluetun_addr: 'https://gluetun/control/',
      gluetun_ssl_verify: true, opnsense_skip: true, opnsense_interface_addr: 'https://firewall/',
      opnsense_alias_name: 'stored_alias', opnsense_ssl_verify: true, qbit_skip: true,
      qbit_addr: 'http://qbit:8080/', qbit_ssl_verify: true }.each { |key, value| settings.set(key, value) }

    response = api_get('/api/about')

    expect(response.status).to eq(200)
    expect(response_json(response)['env_variables']).to include(
      'ui_mode' => nil, 'loop_freq' => 30, 'required_attempts' => nil, 'proton_gateway' => '10.7.0.1',
      'log_lines' => nil, 'log_reverse' => false, 'log_to_stdout' => false,
      'gluetun_addr' => 'https://gluetun/control/', 'gluetun_ssl_verify' => true,
      'opn_skip' => false, 'opn_interface_addr' => nil, 'opn_alias_name' => 'stored_alias',
      'opn_proton_alias_name' => nil, 'opn_ssl_verify' => false,
      'qbit_skip' => false, 'qbit_addr' => nil, 'qbit_ssl_verify' => false,
      'gluetun_api_key' => '***', 'gluetun_user' => '***', 'gluetun_pass' => '***',
      'opn_api_key' => '***', 'opn_api_secret' => '***', 'qbit_api_key' => '***', 'qbit_pass' => '***'
    )
    expect(response.body).not_to include('environment_name', 'environment_override', '"source"')
    expect(Setting.count).to eq(16)
  end

  it 'preserves unset ENV representations and historically effective defaults without creating settings rows' do
    expect(response_json(api_get('/api/about'))['env_variables']).to include(
      'ui_mode' => nil, 'required_attempts' => nil, 'log_lines' => nil,
      'opn_skip' => false, 'opn_interface_addr' => nil, 'opn_ssl_verify' => false,
      'qbit_skip' => false, 'qbit_addr' => nil, 'qbit_ssl_verify' => false,
      'log_reverse' => false, 'log_to_stdout' => false, 'opn_alias_name' => nil, 'opn_proton_alias_name' => nil,
      'loop_freq' => 45, 'proton_gateway' => '10.2.0.1', 'port_source' => 'proton',
      'gluetun_addr' => 'http://gluetun:8000', 'gluetun_ssl_verify' => false
    )
    expect(Setting.count).to eq(0)
  end

  it 'preserves raw ENV strings, case, partial numbers, and established boolean parsing on about' do
    ENV.update('UI_MODE' => 'LiGhT', 'REQUIRED_ATTEMPTS' => '5abc', 'LOG_LINES' => '7000abc',
               'LOG_REVERSE' => 'TRUE', 'LOG_TO_STDOUT' => ' true ', 'OPN_SKIP' => 'TRUE',
               'OPN_INTERFACE_ADDR' => 'https://legacy-firewall/proxy/', 'OPN_SSL_VERIFY' => 'TRUE',
               'QBIT_SKIP' => 'false', 'QBIT_ADDR' => 'http://legacy-qbit:8080/qbit/', 'QBIT_SSL_VERIFY' => ' true ')

    expect(response_json(api_get('/api/about'))['env_variables']).to include(
      'ui_mode' => 'LiGhT', 'required_attempts' => '5abc', 'log_lines' => '7000abc',
      'log_reverse' => true, 'log_to_stdout' => false, 'opn_skip' => true,
      'opn_interface_addr' => 'https://legacy-firewall/proxy/', 'opn_ssl_verify' => true,
      'qbit_skip' => false, 'qbit_addr' => 'http://legacy-qbit:8080/qbit/', 'qbit_ssl_verify' => false
    )
    expect(Setting.count).to eq(0)
  end

  ['', ' '].each do |blank|
    it "retains raw #{blank.inspect} ENV placeholders and their legacy boolean representations on about" do
      %w[UI_MODE REQUIRED_ATTEMPTS LOG_LINES LOG_REVERSE LOG_TO_STDOUT OPN_SKIP OPN_INTERFACE_ADDR
         OPN_SSL_VERIFY QBIT_SKIP QBIT_ADDR QBIT_SSL_VERIFY].each { |name| ENV[name] = blank }

      expect(response_json(api_get('/api/about'))['env_variables']).to include(
        'ui_mode' => blank, 'required_attempts' => blank, 'log_lines' => blank,
        'log_reverse' => false, 'log_to_stdout' => false, 'opn_skip' => false,
        'opn_interface_addr' => blank, 'opn_ssl_verify' => false, 'qbit_skip' => false,
        'qbit_addr' => blank, 'qbit_ssl_verify' => false
      )
      expect(Setting.count).to eq(0)
    end
  end

  it 'keeps the existing about response fields without adding resolution metadata' do
    expect(response_json(api_get('/api/about'))['env_variables'].keys).to contain_exactly(
      *%w[ui_mode loop_freq required_attempts log_lines log_reverse log_to_stdout port_source gluetun_addr
          gluetun_api_key gluetun_user gluetun_pass gluetun_ssl_verify proton_gateway opn_skip opn_interface_addr
          opn_api_key opn_api_secret opn_alias_name opn_proton_alias_name opn_ssl_verify qbit_skip qbit_addr
          qbit_api_key qbit_user qbit_pass qbit_ssl_verify]
    )
  end

  it 'uses the stored alias when both ENV aliases are blank while retaining the raw legacy API field' do
    ENV.update('OPN_ALIAS_NAME' => '', 'OPN_PROTON_ALIAS_NAME' => ' ')
    Service::Settings.new.set(:opnsense_alias_name, 'stored_alias')

    expect(response_json(api_get('/api/about'))['env_variables']).to include(
      'opn_alias_name' => 'stored_alias', 'opn_proton_alias_name' => ' '
    )
  end

  it 'honors stored skip settings in health without hiding a stale enabled target' do
    settings = Service::Settings.new
    settings.set(:opnsense_skip, true)
    settings.set(:qbit_skip, true)
    %w[opnsense qbit].each { |name| Source[name: name].stat.update(last_checked: Time.now - 10_000) }

    response = api_get('/api/health')
    expect(response.status).to eq(200)
    expect(response_json(response)['health']).to eq('protonvpn' => 200, 'opnsense' => 'skipped', 'qbit' => 'skipped')

    settings.set(:qbit_skip, false)
    response = api_get('/api/health')
    expect(response.status).to eq(503)
    expect(response_json(response)['health']).to include('opnsense' => 'skipped', 'qbit' => 503)
  end

  it 'uses normalized configured frequency before synchronization initialization without capturing it' do
    DB[:stats].update(last_checked: Time.now - 20)
    ENV['LOOP_FREQ'] = 'invalid'
    expect(api_get('/api/health').status).to eq(200)
    expect(response_json(api_get('/api/stats'))['stats'].values).to all(include('connected' => true))

    ENV['LOOP_FREQ'] = '1'
    expect(api_get('/api/health').status).to eq(503)
    expect(response_json(api_get('/api/stats'))['stats'].values).to all(include('connected' => false))
  end

  it 'uses stored log count and direction as API log defaults' do
    settings = Service::Settings.new
    settings.set(:log_lines, 75)
    settings.set(:log_reverse, true)
    expect_any_instance_of(Service::Helpers).to receive(:log_lines_to_a).with(75, true).and_return(['newest'])

    expect(response_json(api_get('/api/logs'))).to eq('log_lines' => ['newest'])
  end

  it 'honors a stored OPNsense skip setting for WireGuard tools before creating an integration client' do
    Service::Settings.new.set(:opnsense_skip, true)
    expect(Service::Opnsense).not_to receive(:new)

    expect(api_get('/api/tools/wireguard-targets').status).to eq(503)
    expect(api_post('/api/tools/wireguard-import', {}).status).to eq(503)
  end

  it 'requires the same valid Bearer credential for every API endpoint' do
    missing = api_get('/api/stats', token: nil)
    invalid = api_get('/api/stats', token: "#{ApiKey::TOKEN_PREFIX}#{'0' * 64}")
    basic = api_get('/api/stats', token: @api_token, scheme: 'Basic')

    [missing, invalid, basic].each do |response|
      expect(response.status).to eq(401)
      expect(response_json(response)).to eq('error' => 'unauthorized')
      expect(response['www-authenticate']).to eq('Bearer realm="qbop"')
    end
    expect(api_get('/api/stats').status).to eq(200)
    expect(api_get('/api/health').status).to eq(200)
  end

  it 'updates last use only after successful authentication' do
    expect(api_get('/api/health', token: nil).status).to eq(401)
    expect(api_get('/api/health', token: "#{ApiKey::TOKEN_PREFIX}#{'0' * 64}").status).to eq(401)
    expect(@api_key.refresh.last_used_at).to be_nil

    expect(api_get('/api/health').status).to eq(200)
    expect(@api_key.refresh.last_used_at).not_to be_nil
  end

  it 'supports independent keys and revokes only the deleted key' do
    other = ApiKey.issue('other client')

    expect(api_get('/api/stats').status).to eq(200)
    expect(api_get('/api/stats', token: other.token).status).to eq(200)

    @api_key.delete

    expect(api_get('/api/stats').status).to eq(401)
    expect(api_get('/api/stats', token: other.token).status).to eq(200)
  end

  it 'returns stats by source name' do
    response = api_get('/api/stats')
    body = response_json(response)

    expect(response.status).to eq(200)
    expect(body.dig('stats', 'protonvpn', 'current_port')).to eq(12_345)
    expect(body.dig('records', 'longest_time_on_same_port', 'qbit')).to eq(60)
  end

  it 'reports the selected source through compatible stats and health fields' do
    ENV['PORT_SOURCE'] = 'gluetun'
    source = Source.create(name: 'gluetun')
    Stat.create(source_id: source.id, current_port: 51_820, same_port: 120, last_checked: Time.now)

    stats = response_json(api_get('/api/stats'))
    expect(stats['port_source']).to eq('gluetun')
    expect(stats.dig('stats', 'protonvpn', 'current_port')).to eq(51_820)
    expect(stats.dig('records', 'longest_time_on_same_port', 'proton')).to eq(120)
    expect(response_json(api_get('/api/health'))).to include(
      'port_source' => 'gluetun', 'health' => include('protonvpn' => 200)
    )

    source.stat.update(last_checked: Time.now - 10_000)
    response = api_get('/api/health')
    expect(response.status).to eq(503)
    expect(response_json(response).dig('health', 'protonvpn')).to eq(503)
  end

  it 'includes the source identity in history without changing existing fields' do
    PortTransition.record_transition(
      previous_port: 12_345, new_port: 51_820, source_name: 'gluetun',
      opnsense_skipped: false, qbit_skipped: false
    )

    expect(response_json(api_get('/api/history'))['history'].first).to include(
      'source' => 'gluetun', 'previous_port' => 12_345, 'new_port' => 51_820
    )
  end

  it 'keeps API history historical while stats report the live port during a pending target apply' do
    ENV['PORT_SOURCE'] = 'gluetun'
    Source.create(name: 'gluetun').tap(&:seed_tables).set_current_port(23_456)
    old_history = PortTransition.record_transition(
      previous_port: 12_345, new_port: 23_456, source_name: 'gluetun',
      opnsense_skipped: false, qbit_skipped: false
    )
    PortTransition.mark_synced('opnsense', 23_456, source_name: 'gluetun')
    pending = PortTransition.record_transition(
      previous_port: 34_567, new_port: 23_456, source_name: 'proton',
      opnsense_skipped: false, qbit_skipped: false
    )
    PortTransition.mark_error('opnsense', 23_456, source_name: 'proton')
    target = Source[name: 'opnsense'].tap(&:seed_tables)
    target.set_current_port(34_567)
    target.set_pending_apply(23_456, [pending.id])

    histories = response_json(api_get('/api/history'))['history'].to_h { |row| [row['id'], row] }
    expect(histories[old_history.id].dig('opnsense', 'status')).to eq('synced')
    expect(histories[pending.id].dig('opnsense', 'status')).to eq('error')
    expect(response_json(api_get('/api/stats')).dig('stats', 'opnsense', 'current_port')).to eq(34_567)
    expect(Source[name: 'opnsense'].pending_apply_port).to eq(23_456)
  end

  it 'masks Gluetun credentials in configuration responses' do
    ENV.update('GLUETUN_API_KEY' => 'secret-key', 'GLUETUN_USER' => 'secret-user', 'GLUETUN_PASS' => 'secret-pass',
               'GLUETUN_ADDR' => 'http://secret-user:secret-pass@gluetun:8000/control')
    response = api_get('/api/about')

    expect(response_json(response)['env_variables']).to include(
      'port_source' => 'proton', 'gluetun_api_key' => '***', 'gluetun_user' => '***', 'gluetun_pass' => '***',
      'gluetun_addr' => 'http://***@gluetun:8000/control'
    )
    expect(response.body).not_to include(ENV['GLUETUN_ADDR'], 'secret-key', 'secret-user', 'secret-pass')
  end

  [
    'http://secret-user:secret-pass word@gluetun:8000/control',
    'http:/secret-user:secret-pass@gluetun:8000/control',
    'http:///secret-user:secret-pass@/control',
    'ftp://secret-user:secret-pass@gluetun:8000/control',
    'secret-user:secret-pass@gluetun:8000/control',
    'http://secret-user:secret-pass@gluetun:0/control',
    'http://secret-user:secret-pass@gluetun:65536/control',
    'http://secret-user:secret-pass@gluetun:999999/control',
    'http://secret-user:secret-pass@gluetun:8000/control?api_key=query-secret',
    'http://secret-user:secret-pass@gluetun:8000/control#fragment-secret',
    'http://gluetun:8000/control?',
    'http://gluetun:8000/control#'
  ].each do |address|
    it "hides rejected Gluetun addresses in configuration responses: #{address}" do
      ENV['GLUETUN_ADDR'] = address
      response = api_get('/api/about')

      expect(response.status).to eq(200)
      expect(response_json(response)['env_variables']['gluetun_addr']).to eq('[invalid URL]')
      expect(response.body).not_to include(address, 'secret-user', 'secret-pass', 'query-secret', 'fragment-secret')
    end
  end

  %w[http://gluetun:8000 http://gluetun https://gluetun https://gluetun:8000/control/
     http://gluetun:1/control/ https://gluetun:65535/control/].each do |address|
    it "preserves supported Gluetun addresses in configuration responses: #{address}" do
      ENV['GLUETUN_ADDR'] = address

      expect(response_json(api_get('/api/about'))['env_variables']['gluetun_addr']).to eq(address)
    end
  end

  it 'returns healthy status when all services checked in recently' do
    response = api_get('/api/health')

    expect(response.status).to eq(200)
    expect(response_json(response)['health'].values).to all(eq(200))
  end

  it 'returns unhealthy status when any service is stale' do
    DB[:stats].where(source_id: Source[name: 'qbit'].id).update(last_checked: Time.now - 10_000)

    response = api_get('/api/health')

    expect(response.status).to eq(503)
    expect(response_json(response).dig('health', 'qbit')).to eq(503)
  end

  it 'ignores skipped services for health status' do
    ENV['QBIT_SKIP'] = 'true'
    DB[:stats].where(source_id: Source[name: 'qbit'].id).update(last_checked: Time.now - 10_000)

    response = api_get('/api/health')

    expect(response.status).to eq(200)
    expect(response_json(response).dig('health', 'qbit')).to eq('skipped')
  end

  it 'returns a default notification when no notification exists' do
    response = api_get('/api/notifications')

    expect(response_json(response)['notifications']).to eq(
      'name' => 'update_available',
      'info' => nil,
      'active' => false
    )
  end

  it 'returns the update notification when it exists' do
    Notification.create(name: 'update_available', info: 'v2.7.0', active: true)

    response = api_get('/api/notifications')

    expect(response_json(response)['notifications']).to include('info' => 'v2.7.0', 'active' => true)
  end

  it 'keeps the deprecated GET public key endpoint functional' do
    ENV['OPN_SKIP'] = 'true'
    allow_any_instance_of(Service::Helpers).to receive(:generate_wg_public_key).and_return('public-key')

    response = api_get('/api/tools/pubkey?private-key=private-key')

    expect(response_json(response)['public_key']).to eq('public-key')
  end

  it 'derives a public key from a private key in the POST JSON body' do
    ENV['OPN_SKIP'] = 'true'
    private_key = Base64.strict_encode64("\x01" * 32)
    public_key = Base64.strict_encode64("\x02" * 32)
    expect_any_instance_of(Service::Helpers).to receive(:generate_wg_public_key)
      .with(private_key).and_return(public_key)

    response = api_post('/api/tools/pubkey', { private_key: private_key })

    expect(response.status).to eq(200)
    expect(response_json(response)).to eq('public_key' => public_key)
    expect(response.body).not_to include(private_key)
  end

  it 'rejects a missing POST private key' do
    expect_any_instance_of(Service::Helpers).not_to receive(:generate_wg_public_key)

    response = api_post('/api/tools/pubkey', {})

    expect(response.status).to eq(422)
    expect(response_json(response)).to eq('error' => 'private_key is required')
  end

  it 'rejects a malformed POST private key without returning it' do
    private_key = 'distinctive-malformed-api-private-key'
    expect_any_instance_of(Service::Helpers).not_to receive(:generate_wg_public_key)

    response = api_post('/api/tools/pubkey', { private_key: private_key })

    expect(response.status).to eq(422)
    expect(response_json(response)).to eq('error' => 'private_key is not a valid wireguard key')
    expect(response.body).not_to include(private_key)
  end

  it 'returns a generic error when POST public-key derivation fails' do
    private_key = Base64.strict_encode64("\x01" * 32)
    allow_any_instance_of(Service::Helpers).to receive(:generate_wg_public_key)
      .with(private_key).and_return('wg derivation failed')

    response = api_post('/api/tools/pubkey', { private_key: private_key })

    expect(response.status).to eq(422)
    expect(response_json(response)).to eq('error' => 'could not derive wireguard public key')
    expect(response.body).not_to include(private_key, 'wg derivation failed')
  end

  it 'does not consume a POST private key from the query string' do
    private_key = 'distinctive-query-api-private-key'
    expect_any_instance_of(Service::Helpers).not_to receive(:generate_wg_public_key)

    response = api_post("/api/tools/pubkey?private_key=#{private_key}", {})

    expect(response.status).to eq(422)
    expect(response_json(response)).to eq(
      'error' => 'private_key must be provided in the JSON request body'
    )
    expect(response.body).not_to include(private_key)
  end

  it 'returns selectable OPNsense WireGuard targets' do
    ENV['OPN_SKIP'] = 'false'
    targets = {
      instances: [{ uuid: '11111111-1111-4111-8111-111111111111', name: 'proton-instance' }],
      peers: [{ uuid: '22222222-2222-4222-8222-222222222222', name: 'proton-peer' }]
    }
    allow_any_instance_of(Service::Opnsense).to receive(:wireguard_targets).and_return(targets)

    response = api_get('/api/tools/wireguard-targets')

    expect(response.status).to eq(200)
    expect(response_json(response)['wireguard_targets']).to eq(JSON.parse(targets.to_json))
  end

  it 'does not load WireGuard targets when OPNsense integration is skipped' do
    ENV['OPN_SKIP'] = 'true'
    expect(Service::Opnsense).not_to receive(:new)

    response = api_get('/api/tools/wireguard-targets')

    expect(response.status).to eq(503)
    expect(response_json(response)['error']).to eq(
      'proton wireguard import is unavailable because opnsense integration is disabled.'
    )
  end

  it 'does not parse or rotate WireGuard configuration when OPNsense integration is skipped' do
    ENV['OPN_SKIP'] = 'true'
    submitted_config = "[Interface]\nPrivateKey = distinctive-skipped-api-private-config-value"
    expect(Service::Opnsense).not_to receive(:new)
    expect(Service::ProtonWireguard).not_to receive(:new)
    expect(Service::ProtonWireguardRotation).not_to receive(:new)

    response = api_post(
      '/api/tools/wireguard-import',
      { config: submitted_config, instance_uuid: 'instance', peer_uuid: 'peer' }
    )

    expect(response.status).to eq(503)
    expect(response_json(response)['error']).to eq(
      'proton wireguard import is unavailable because opnsense integration is disabled.'
    )
    expect(response.body).not_to include('distinctive-skipped-api-private-config-value', 'PrivateKey')
  end

  it 'completes a ProtonVPN WireGuard rotation without returning its private values' do # rubocop:disable Metrics/BlockLength
    ENV['OPN_SKIP'] = 'false'
    instance_uuid = '11111111-1111-4111-8111-111111111111'
    peer_uuid = '22222222-2222-4222-8222-222222222222'
    parsed = {
      instance: { private_key: 'private-key' },
      peer: {},
      metadata: { proton_server_identifier: 'US-IL#661' }
    }
    allow_any_instance_of(Service::ProtonWireguard).to receive(:import).and_return(parsed)
    rotation = instance_double(Service::ProtonWireguardRotation)
    allow(Service::ProtonWireguardRotation).to receive(:new).and_return(rotation)
    expect(rotation).to receive(:rotate).with(
      parsed,
      instance_uuid: instance_uuid,
      peer_uuid: peer_uuid,
      rename_peer: true
    ).and_return(instance_name: 'proton-instance', peer_name: 'Proton_US-IL661')

    response = api_post(
      '/api/tools/wireguard-import',
      {
        config: "[Interface]\nPrivateKey = distinctive-private-config-value",
        instance_uuid: instance_uuid,
        peer_uuid: peer_uuid,
        rename_peer: true
      }
    )
    body = response_json(response)

    expect(response.status).to eq(200)
    expect(body['wireguard_import']).to eq(
      'instance_name' => 'proton-instance', 'peer_name' => 'Proton_US-IL661'
    )
    expect(response.body).not_to include('private-key', 'distinctive-private-config-value', '[Interface]')
  end

  it 'rejects requested peer renaming without server metadata before contacting OPNsense' do
    instance_uuid = '11111111-1111-4111-8111-111111111111'
    peer_uuid = '22222222-2222-4222-8222-222222222222'
    allow_any_instance_of(Service::ProtonWireguard).to receive(:import).and_return(
      instance: {}, peer: {}, metadata: {}
    )
    opnsense = instance_double(Service::Opnsense)
    allow(Service::Opnsense).to receive(:new).and_return(opnsense)

    response = api_post(
      '/api/tools/wireguard-import',
      {
        config: '[Interface]',
        instance_uuid: instance_uuid,
        peer_uuid: peer_uuid,
        rename_peer: true
      }
    )

    expect(response.status).to eq(422)
    expect(response_json(response)['error']).to include(
      'unable to rename peer because a proton server identifier was not found'
    )
  end

  it 'returns conflict when another WireGuard rotation is in progress' do
    allow_any_instance_of(Service::ProtonWireguard).to receive(:import).and_return(
      instance: {}, peer: {}
    )
    rotation = instance_double(Service::ProtonWireguardRotation)
    allow(Service::ProtonWireguardRotation).to receive(:new).and_return(rotation)
    allow(rotation).to receive(:rotate)
      .and_raise(Service::ProtonWireguardRotation::Busy, 'another rotation is already in progress')

    response = api_post(
      '/api/tools/wireguard-import',
      { config: '[Interface]', instance_uuid: 'instance', peer_uuid: 'peer' }
    )

    expect(response.status).to eq(409)
    expect(response_json(response)['error']).to include('another rotation is already in progress')
  end

  it 'returns the rollback outcome when a synchronous WireGuard rotation fails' do
    allow_any_instance_of(Service::ProtonWireguard).to receive(:import).and_return(
      instance: { private_key: 'private-key' }, peer: {}
    )
    rotation = instance_double(Service::ProtonWireguardRotation)
    allow(Service::ProtonWireguardRotation).to receive(:new).and_return(rotation)
    allow(rotation).to receive(:rotate).and_raise(
      Service::ProtonWireguardRotation::Error,
      'OPNsense WireGuard rotation failed: apply failed; rollback completed'
    )

    response = api_post(
      '/api/tools/wireguard-import',
      { config: '[Interface]', instance_uuid: 'instance', peer_uuid: 'peer' }
    )

    expect(response.status).to eq(422)
    expect(response_json(response)['error']).to end_with('apply failed; rollback completed')
    expect(response.body).not_to include('private-key', '[Interface]')
  end

  it 'returns unknown provider details for unsupported public IP providers' do
    ENV['OPN_SKIP'] = 'true'
    response = api_get('/api/tools/public-ip?service=invalid')

    expect(response_json(response)['public_ip']).to start_with('Unknown provider')
  end

  it 'returns log lines' do
    allow_any_instance_of(Service::Helpers).to receive(:log_lines_to_a).and_return(["line one\n", "line two\n"])

    response = api_get('/api/logs')

    expect(response_json(response)['log_lines']).to eq(['line one', 'line two'])
  end

  it 'returns log lines using query string controls' do
    expect_any_instance_of(Service::Helpers)
      .to receive(:log_lines_to_a)
      .with(500, true)
      .and_return(["line one\n", "line two\n"])

    response = api_get('/api/logs?lines=500&direction=desc')

    expect(response_json(response)).to eq('log_lines' => ['line one', 'line two'])
  end

  it 'returns paginated port transition history' do # rubocop:disable Metrics/BlockLength
    30.times do |index|
      PortTransition.record_transition(
        previous_port: index + 10_000,
        new_port: index + 10_001,
        opnsense_skipped: false,
        qbit_skipped: index.zero?,
        detected_at: Time.at(index)
      )
    end
    PortTransition.mark_synced('opnsense', 10_001, at: Time.at(30))
    PortTransition.mark_error('qbit', 10_002, at: Time.at(31))

    response = api_get('/api/history?page=2&per_page=25')
    body = response_json(response)

    expect(response.status).to eq(200)
    expect(body['history'].length).to eq(5)
    expect(body['history'].first['new_port']).to eq(10_005)
    expect(body['history'].last).to include(
      'previous_port' => 10_000,
      'new_port' => 10_001,
      'opnsense' => include('status' => 'synced'),
      'qbit' => include('status' => 'skipped')
    )
    errored_transition = body['history'].find { |transition| transition['new_port'] == 10_002 }
    expect(errored_transition['qbit']).to eq('status' => 'error', 'synced_at' => nil)
    expect(errored_transition['qbit']).not_to have_key('error_at')
    expect(body['pagination']).to eq(
      'total_records' => 30,
      'current_page' => 2,
      'per_page' => 25,
      'total_pages' => 2,
      'from' => 26,
      'to' => 30
    )
  end

  it 'constrains invalid history API pagination parameters' do
    PortTransition.record_transition(
      previous_port: 12_345,
      new_port: 23_456,
      opnsense_skipped: false,
      qbit_skipped: false
    )

    response = api_get('/api/history?page=999&per_page=500')
    pagination = response_json(response)['pagination']

    expect(pagination).to include(
      'current_page' => 1,
      'per_page' => 25,
      'total_records' => 1
    )
  end

  it 'returns about information' do
    ENV['VERSION'] = 'v2.9.0'
    ENV['COMMIT_SHA'] = '0123456789abcdef'
    ENV['BUILD_DATE'] = '2026-08-11T12:34:56Z'
    ENV['LOOP_FREQ'] = 'invalid'
    ENV['PROTON_GATEWAY'] = ''
    response = api_get('/api/about')
    body = response_json(response)

    expect(response.status).to eq(200)
    expect(body.dig('about', 'app_version')).to eq('v2.9.0')
    expect(body.dig('about', 'commit_sha')).to eq('0123456789abcdef')
    expect(body.dig('about', 'build_date')).to eq('2026-08-11T12:34:56Z')
    expect(body.dig('about', 'schema_version')).to eq('unknown')
    expect(body.dig('env_variables', 'loop_freq')).to eq(45)
    expect(body.dig('env_variables', 'proton_gateway')).to eq('10.2.0.1')
    expect(body.dig('env_variables', 'opn_ssl_verify')).to eq(false)
    expect(body['env_variables'].keys).not_to include(
      'basic_auth_enabled', 'basic_auth_user', 'basic_auth_pass'
    )
  end

  [nil, 'preferred_alias', '  '].each do |preferred|
    it "presents the effective alias and retains the legacy API field with preferred #{preferred.inspect}" do
      ENV['OPN_ALIAS_NAME'] = preferred
      ENV['OPN_PROTON_ALIAS_NAME'] = 'legacy_alias'
      expected = preferred == 'preferred_alias' ? preferred : 'legacy_alias'

      expect(response_json(api_get('/api/about'))['env_variables']).to include(
        'opn_alias_name' => expected, 'opn_proton_alias_name' => 'legacy_alias'
      )
    end
  end
end
