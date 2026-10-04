require 'bundler/setup'
Bundler.require(:default)

require 'rack/mock'
require 'stringio'
require_relative '../support/database_helper'
require_relative '../../service/helpers'
require_relative '../../framework/uptime'
require_relative '../../framework/web'

SpecDatabase.reset!
Framework::Web.set :environment, :test
Framework::Web.set :run, false
Framework::Web.set :views, File.expand_path('../../views', __dir__)

RSpec.describe Framework::Web do # rubocop:disable Metrics/BlockLength
  def web_request
    @web_request ||= Rack::MockRequest.new(lambda do |env|
      env['qbop.auth_config'] = Framework::AuthenticationConfig.new
      scope = double('rodauth scope', valid_csrf?: true)
      rodauth = double('rodauth', scope: scope, logged_in?: false)
      allow(rodauth).to receive(:csrf_tag).and_return('')
      env['rodauth'] = rodauth
      described_class.call(env)
    end)
  end

  around do |example| # rubocop:disable Metrics/BlockLength
    source_env_keys = %w[PORT_SOURCE GLUETUN_ADDR GLUETUN_API_KEY GLUETUN_USER GLUETUN_PASS
                         OPN_ALIAS_NAME OPN_PROTON_ALIAS_NAME]
    source_env = source_env_keys.to_h { |key| [key, ENV[key]] }
    source_env_keys.each { |key| ENV.delete(key) }
    version = ENV['VERSION']
    commit_sha = ENV['COMMIT_SHA']
    build_date = ENV['BUILD_DATE']
    web_auth_enabled = ENV['WEB_AUTH_ENABLED']
    opnsense_skip = ENV['OPN_SKIP']
    loop_freq = ENV['LOOP_FREQ']
    proton_gateway = ENV['PROTON_GATEWAY']
    ENV.delete('VERSION')
    ENV.delete('COMMIT_SHA')
    ENV.delete('BUILD_DATE')
    ENV.delete('OPN_SKIP')
    ENV.delete('LOOP_FREQ')
    ENV.delete('PROTON_GATEWAY')
    ENV['WEB_AUTH_ENABLED'] = 'false'
    example.run
  ensure
    source_env_keys.each { |key| source_env[key].nil? ? ENV.delete(key) : ENV[key] = source_env[key] }
    version.nil? ? ENV.delete('VERSION') : ENV['VERSION'] = version
    commit_sha.nil? ? ENV.delete('COMMIT_SHA') : ENV['COMMIT_SHA'] = commit_sha
    build_date.nil? ? ENV.delete('BUILD_DATE') : ENV['BUILD_DATE'] = build_date
    web_auth_enabled.nil? ? ENV.delete('WEB_AUTH_ENABLED') : ENV['WEB_AUTH_ENABLED'] = web_auth_enabled
    opnsense_skip.nil? ? ENV.delete('OPN_SKIP') : ENV['OPN_SKIP'] = opnsense_skip
    loop_freq.nil? ? ENV.delete('LOOP_FREQ') : ENV['LOOP_FREQ'] = loop_freq
    proton_gateway.nil? ? ENV.delete('PROTON_GATEWAY') : ENV['PROTON_GATEWAY'] = proton_gateway
  end

  before do
    SpecDatabase.reset!
    %w[proton opnsense qbit].each do |name|
      source = Source.create(name: name)
      Stat.create(source_id: source.id, current_port: 12_345, same_port: 60)
    end
  end

  it 'renders the stats page without an update notification row' do
    response = web_request.get('/')

    expect(response.status).to eq(200)
    expect(response.body).to include('protonvpn')
    expect(response.body).to include('unknown')
  end

  it 'renders Gluetun status from its own state and synchronization history' do
    ENV['PORT_SOURCE'] = 'gluetun'
    source = Source.create(name: 'gluetun')
    Stat.create(source_id: source.id, current_port: 51_820, same_port: 60, last_checked: Time.now)
    PortTransition.record_transition(
      previous_port: 12_345, new_port: 51_820, source_name: 'gluetun',
      opnsense_skipped: false, qbit_skipped: false
    )
    PortTransition.record_transition(
      previous_port: 12_345, new_port: 51_820, opnsense_skipped: true, qbit_skipped: true
    )

    response = web_request.get('/')

    expect(response.status).to eq(200)
    expect(response.body).to include('<em>gluetun</em>', 'current port: 51820', 'sync: pending')
    expect(response.body).not_to include('<em>protonvpn</em>', 'sync: skipped')
    expect(web_request.get('/history').body).to include('<th>source</th>', '<td>gluetun</td>', '<td>proton</td>')
  end

  it 'masks Gluetun credentials on the about page' do
    ENV.update('GLUETUN_API_KEY' => 'secret-key', 'GLUETUN_USER' => 'secret-user', 'GLUETUN_PASS' => 'secret-pass',
               'GLUETUN_ADDR' => 'http://secret-user:secret-pass@gluetun:8000/control')
    response = web_request.get('/about')

    expect(response.body).to include('PORT_SOURCE: proton', 'GLUETUN_API_KEY: ***', 'GLUETUN_SSL_VERIFY: false',
                                     'GLUETUN_ADDR: http://***@gluetun:8000/control')
    expect(response.body).not_to include('secret-key', 'secret-user', 'secret-pass')
  end

  ['?api_key=query-secret', '#fragment-secret'].each do |suffix|
    it "hides rejected Gluetun URL tokens on the about page: #{suffix}" do
      ENV['GLUETUN_ADDR'] = "http://secret-user:secret-pass@gluetun:8000/control#{suffix}"
      response = web_request.get('/about')

      expect(response.body).to include('GLUETUN_ADDR: [invalid URL]')
      expect(response.body).not_to include('secret-user', 'secret-pass', 'query-secret', 'fragment-secret')
    end
  end

  ['preferred_alias', '  '].each do |preferred|
    it "displays the effective alias with preferred #{preferred.inspect} while retaining legacy configuration" do
      ENV['OPN_ALIAS_NAME'] = preferred
      ENV['OPN_PROTON_ALIAS_NAME'] = 'legacy_alias'
      expected = preferred == 'preferred_alias' ? preferred : 'legacy_alias'

      expect(web_request.get('/about').body).to include(
        "OPN_ALIAS_NAME: #{expected}", 'OPN_PROTON_ALIAS_NAME: legacy_alias'
      )
    end
  end

  it 'ignores legacy refresh parameters and enables live status updates' do
    response = web_request.get('/?refresh=5')

    expect(response.status).to eq(200)
    expect(response.body).not_to include('http-equiv="refresh"', 'auto-refresh', 'name="refresh"')
  end

  it 'renders update notification details when present' do
    ENV['VERSION'] = 'v2.6.0'
    Notification.create(name: 'update_available', info: 'v2.7.0', active: true)

    response = web_request.get('/about')

    expect(response.status).to eq(200)
    expect(response.body).to include(
      '<div class="terminal-alert terminal-alert-primary">' \
      '<a href="https://github.com/clajiness/qbop/releases" target="_blank">an update is available:</a> ' \
      '<a href="https://github.com/clajiness/qbop/releases/tag/v2.7.0" target="_blank">v2.7.0</a></div>'
    )
    expect(response.body).to match(
      %r{<h4><em>image</em></h4>\s*<blockquote>\s*commit:\s*unknown\s*<br>\s*built: unknown\s*</blockquote>}
    )
    headings = response.body.scan(%r{<h4><em>(.*?)</em></h4>}).flatten
    expect(headings.first(6)).to eq(
      ['app version', 'image', 'schema version', 'ruby version', 'app uptime', 'github repo']
    )
    expect(headings).not_to include('commit', 'build date')
    expect(response.body).not_to include('BASIC_AUTH_ENABLED', 'BASIC_AUTH_USER', 'BASIC_AUTH_PASS')
  end

  it 'always shows authentication defaults while masking secrets' do
    response = web_request.get('/about')

    expect(response.body).to include(
      'WEB_AUTH_ENABLED: false',
      'OIDC_ENABLED: false',
      'OIDC_ISSUER: <br>',
      'OIDC_CLIENT_ID: <br>',
      'OIDC_CLIENT_SECRET: ***',
      'OIDC_PUBLIC_URL: <br>',
      'OIDC_AUTO_REDIRECT: false',
      'LOCAL_LOGIN_ENABLED: true'
    )
  end

  it 'renders main build identity without a release status' do
    ENV['VERSION'] = 'main'
    ENV['COMMIT_SHA'] = '0123456789abcdef'
    ENV['BUILD_DATE'] = '2026-08-11T12:34:56Z'
    Notification.create(name: 'update_available', info: 'v2.7.0', active: true)

    response = web_request.get('/about')

    expect(response.status).to eq(200)
    expect(response.body).to include('tracking main')
    expect(response.body.scan('<h4><em>image</em></h4>').length).to eq(1)
    expect(response.body).to match(
      %r{
        <h4><em>image</em></h4>\s*
        <blockquote>\s*commit:\s*<a [^>]+>0123456789ab</a>\s*
        <br>\s*built:\s*2026-08-11T12:34:56Z\s*</blockquote>
      }x
    )
    expect(response.body).not_to include('an update is available')
  end

  it 'renders current server uptime on each About page load without a refresh button' do
    allow(Framework::Uptime).to receive(:uptime_seconds).and_return(90_061, 90_063)

    response = web_request.get('/about')

    expect(response.status).to eq(200)
    expect(response.body).to include('1d, 1h, 1m, 1s')
    expect(response.body).not_to include('window.location.reload', '>refresh</button>')
    expect(response.body).not_to include('uptime.js', 'data-uptime-seconds', 'sse-connect=', 'http-equiv="refresh"')
    expect(web_request.get('/about').body).to include('1d, 1h, 1m, 3s')
  end

  it 'renders the tools page' do
    targets = {
      instances: [{ uuid: '11111111-1111-4111-8111-111111111111', name: 'proton-instance', interface: 'wg0' }],
      peers: [{ uuid: '22222222-2222-4222-8222-222222222222', name: 'proton-peer' }]
    }
    allow_any_instance_of(Service::Opnsense).to receive(:wireguard_targets).and_return(targets)

    response = web_request.get('/tools')
    card_headers = response.body.scan(%r{<header>(.*?)</header>}).flatten

    expect(response.status).to eq(200)
    expect(card_headers.first(3)).to eq(
      ['import protonvpn wireguard config', 'generate wireguard public key', 'get public ip address']
    )
    expect(response.body).to include('proton-instance - wg0', 'proton-peer', 'update a dedicated opnsense instance')
    expect(response.body).to include(
      'id="wireguardrenamepeer"',
      'rename peer to match new proton server',
      "uses proton's server identifier to generate a name such as",
      '<code>Proton_US-IL661</code>'
    )
    checkbox = response.body[/<input[^>]+id="wireguardrenamepeer"[^>]*>/]
    expect(checkbox).not_to include('disabled', 'checked')
    expect(response.body).not_to include(
      'protonPeerName', 'FileReader', 'wireguardrenamepeerlabel',
      'reload tools to use the wireguard importer'
    )
  end

  it 'keeps the tools page available without loading WireGuard targets when OPNsense is skipped' do
    ENV['OPN_SKIP'] = 'true'
    expect_any_instance_of(Service::Opnsense).not_to receive(:wireguard_targets)

    response = web_request.get('/tools')

    expect(response.status).to eq(200)
    expect(response.body).to include(
      'proton wireguard import requires opnsense integration.',
      'generate wireguard public key',
      'get public ip address'
    )
    expect(response.body).not_to include('id="wgimportform"')
    expect(response.body).not_to include('reload tools to use the wireguard importer')
  end

  it 'does not process a WireGuard import when OPNsense is skipped' do
    ENV['OPN_SKIP'] = 'true'
    submitted_config = '[Interface] distinctive-skipped-private-config-value'
    expect_any_instance_of(Service::Opnsense).not_to receive(:wireguard_targets)
    expect_any_instance_of(Service::ProtonWireguard).not_to receive(:import)
    expect(Service::ProtonWireguardRotation).not_to receive(:new)

    response = web_request.post(
      '/wireguard-import', input: URI.encode_www_form(wireguardconfig: submitted_config)
    )

    expect(response.status).to eq(200)
    expect(response.body).to include('proton wireguard import requires opnsense integration.')
    expect(response.body).not_to include('distinctive-skipped-private-config-value')
  end

  it 'keeps the tools page available when WireGuard target loading fails' do
    allow_any_instance_of(Service::Opnsense).to receive(:wireguard_targets).and_raise(
      Service::Opnsense::WireguardImportError, 'could not load OPNsense WireGuard targets: unavailable'
    )

    response = web_request.get('/tools')

    expect(response.status).to eq(200)
    expect(response.body).to include(
      'could not load OPNsense WireGuard targets: unavailable',
      'generate wireguard public key',
      'get public ip address'
    )
    expect(response.body).not_to include('id="wgimportform"')
    expect(response.body).not_to include('reload tools to use the wireguard importer')
  end

  it 'updates the selected OPNsense WireGuard instance and peer synchronously' do # rubocop:disable Metrics/BlockLength
    instance_uuid = '11111111-1111-4111-8111-111111111111'
    peer_uuid = '22222222-2222-4222-8222-222222222222'
    parsed = {
      instance: {}, peer: {}, metadata: { proton_server_identifier: 'US-IL#661' }
    }
    targets = {
      instances: [{ uuid: instance_uuid, name: 'proton-instance', interface: 'wg0' }],
      peers: [{ uuid: peer_uuid, name: 'proton-peer' }]
    }
    submitted_config = 'uploaded distinctive-rename-private-config-value'
    allow_any_instance_of(Service::ProtonWireguard).to receive(:import).with(submitted_config).and_return(parsed)
    allow_any_instance_of(Service::Opnsense).to receive(:wireguard_targets).and_return(targets)
    rotation = instance_double(Service::ProtonWireguardRotation)
    allow(Service::ProtonWireguardRotation).to receive(:new).and_return(rotation)
    expect(rotation).to receive(:rotate).with(
      parsed,
      instance_uuid: instance_uuid,
      peer_uuid: peer_uuid,
      rename_peer: true
    ).and_return(instance_name: 'proton-instance', peer_name: 'Proton_US-IL661')

    uploaded = Rack::Multipart::UploadedFile.new(
      nil, 'text/plain', false, filename: 'proton.conf', io: StringIO.new(submitted_config)
    )
    multipart = Rack::Multipart.build_multipart(
      {
        wireguardconfig: 'stale pasted config',
        wireguardfile: uploaded,
        wireguardinstance: instance_uuid,
        wireguardpeer: peer_uuid,
        wireguardrenamepeer: 'true'
      }
    )
    response = web_request.post(
      '/wireguard-import',
      'CONTENT_TYPE' => "multipart/form-data; boundary=#{Rack::Multipart::MULTIPART_BOUNDARY}",
      input: multipart
    )

    expect(response.status).to eq(200)
    expect(response.body).to include('updated instance proton-instance and peer Proton_US-IL661')
    expect(response.body).to include("value=\"#{instance_uuid}\" selected", "value=\"#{peer_uuid}\" selected")
    expect(response.body).not_to include('distinctive-rename-private-config-value', 'stale pasted config')
  end

  it 'does not render a pasted private configuration after a parsing failure' do
    submitted_config = "[Interface]\nPrivateKey = distinctive-private-config-value"
    allow_any_instance_of(Service::Opnsense).to receive(:wireguard_targets).and_return(instances: [], peers: [])

    response = web_request.post(
      '/wireguard-import', input: URI.encode_www_form(wireguardconfig: submitted_config)
    )

    expect(response.status).to eq(200)
    expect(response.body).to include('missing Address')
    expect(response.body).not_to include('distinctive-private-config-value')
  end

  it 'does not render a pasted private configuration after a successful rename' do # rubocop:disable Metrics/BlockLength
    submitted_config = '[Interface] distinctive-success-private-config-value'
    instance_uuid = '11111111-1111-4111-8111-111111111111'
    peer_uuid = '22222222-2222-4222-8222-222222222222'
    parsed = {
      instance: {}, peer: {}, metadata: { proton_server_identifier: 'SE#108' }
    }
    allow_any_instance_of(Service::ProtonWireguard).to receive(:import).with(submitted_config).and_return(parsed)
    allow_any_instance_of(Service::Opnsense).to receive(:wireguard_targets).and_return(instances: [], peers: [])
    rotation = instance_double(Service::ProtonWireguardRotation)
    allow(Service::ProtonWireguardRotation).to receive(:new).and_return(rotation)
    expect(rotation).to receive(:rotate).with(
      parsed,
      instance_uuid: instance_uuid,
      peer_uuid: peer_uuid,
      rename_peer: true
    ).and_return(instance_name: 'proton-instance', peer_name: 'Proton_SE108')

    response = web_request.post(
      '/wireguard-import',
      input: URI.encode_www_form(
        wireguardconfig: submitted_config,
        wireguardinstance: instance_uuid,
        wireguardpeer: peer_uuid,
        wireguardrenamepeer: 'true'
      )
    )

    expect(response.status).to eq(200)
    expect(response.body).to include('updated instance proton-instance and peer Proton_SE108')
    expect(response.body).not_to include('distinctive-success-private-config-value')
  end

  it 'does not render a pasted private configuration after a rotation failure' do
    submitted_config = '[Interface] distinctive-rotation-private-config-value'
    allow_any_instance_of(Service::ProtonWireguard).to receive(:import).and_return(instance: {}, peer: {})
    allow_any_instance_of(Service::Opnsense).to receive(:wireguard_targets).and_return(instances: [], peers: [])
    rotation = instance_double(Service::ProtonWireguardRotation)
    allow(Service::ProtonWireguardRotation).to receive(:new).and_return(rotation)
    allow(rotation).to receive(:rotate).and_raise(
      Service::ProtonWireguardRotation::Error, 'rotation failed; rollback completed'
    )

    response = web_request.post(
      '/wireguard-import', input: URI.encode_www_form(wireguardconfig: submitted_config)
    )

    expect(response.status).to eq(200)
    expect(response.body).to include('rotation failed; rollback completed')
    expect(response.body).not_to include('distinctive-rotation-private-config-value')
  end

  it 'returns conflict when another WireGuard rotation is in progress' do
    submitted_config = '[Interface] distinctive-busy-private-config-value'
    targets = { instances: [], peers: [] }
    allow_any_instance_of(Service::ProtonWireguard).to receive(:import).and_return(
      instance: {}, peer: {}
    )
    allow_any_instance_of(Service::Opnsense).to receive(:wireguard_targets).and_return(targets)
    rotation = instance_double(Service::ProtonWireguardRotation)
    allow(Service::ProtonWireguardRotation).to receive(:new).and_return(rotation)
    allow(rotation).to receive(:rotate)
      .and_raise(Service::ProtonWireguardRotation::Busy, 'another rotation is already in progress')

    response = web_request.post(
      '/wireguard-import', input: URI.encode_www_form(wireguardconfig: submitted_config)
    )

    expect(response.status).to eq(409)
    expect(response.body).to include('another rotation is already in progress')
    expect(response.body).not_to include('distinctive-busy-private-config-value')
  end

  it 'renders public key tool results without loading WireGuard targets' do
    expect(Service::Opnsense).not_to receive(:new)
    allow_any_instance_of(Service::Helpers).to receive(:generate_wg_public_key).and_return('public-key')

    response = web_request.post('/pubkey', input: 'privatekey=private-key')

    expect(response.status).to eq(200)
    expect(response.body).to include('public-key')
    expect(response.body).to include('href="/tools">reload tools to use the wireguard importer</a>')
    expect(response.body).not_to include('could not load OPNsense WireGuard targets')
  end

  it 'renders public key and public IP results without loading targets when OPNsense is skipped' do
    ENV['OPN_SKIP'] = 'true'
    expect(Service::Opnsense).not_to receive(:new)
    allow_any_instance_of(Service::Helpers).to receive(:generate_wg_public_key).and_return('public-key')
    allow_any_instance_of(Service::Helpers).to receive(:get_public_ip).and_return('192.0.2.1')

    public_key_response = web_request.post('/pubkey', input: 'privatekey=private-key')
    public_ip_response = web_request.post('/public-ip', input: 'select=akamai')

    expect(public_key_response.status).to eq(200)
    expect(public_key_response.body).to include('public-key')
    expect(public_key_response.body).to include('proton wireguard import requires opnsense integration.')
    expect(public_key_response.body).not_to include('reload tools to use the wireguard importer')
    expect(public_ip_response.status).to eq(200)
    expect(public_ip_response.body).to include('akamai -&gt; 192.0.2.1')
    expect(public_ip_response.body).to include('proton wireguard import requires opnsense integration.')
    expect(public_ip_response.body).not_to include('reload tools to use the wireguard importer')
  end

  it 'renders public IP tool results without loading WireGuard targets' do
    expect(Service::Opnsense).not_to receive(:new)
    allow_any_instance_of(Service::Helpers).to receive(:get_public_ip).and_return('192.0.2.1')

    response = web_request.post('/public-ip', input: 'select=akamai')

    expect(response.status).to eq(200)
    expect(response.body).to include('akamai -&gt; 192.0.2.1')
    expect(response.body).to include('href="/tools">reload tools to use the wireguard importer</a>')
    expect(response.body).not_to include('could not load OPNsense WireGuard targets')
  end

  it 'allowlists public IP providers without reflecting invalid input' do
    expect_any_instance_of(Service::Helpers).not_to receive(:get_public_ip)
    provider = '"><script>provider()</script><input value="'

    invalid_provider_response = web_request.post(
      '/public-ip', input: URI.encode_www_form(select: provider)
    )

    expect(invalid_provider_response.body).to include('value="unknown provider"')
    expect(invalid_provider_response.body).not_to include(provider, '<script>provider()</script>')
  end

  it 'escapes both dynamic tool-result attributes' do
    allow_any_instance_of(Service::Helpers).to receive(:generate_wg_public_key)
      .and_return('"><script>key()</script>')
    allow_any_instance_of(Service::Helpers).to receive(:get_public_ip)
      .and_return('"><script>address()</script>')
    key_response = web_request.post('/pubkey', input: 'privatekey=private-key')
    public_ip_response = web_request.post('/public-ip', input: 'select=akamai')

    expect(key_response.body).to include('&quot;&gt;&lt;script&gt;key()&lt;/script&gt;')
    expect(key_response.body).not_to include('<script>key()</script>')
    expect(public_ip_response.body).to include('akamai -&gt; &quot;&gt;&lt;script&gt;address()&lt;/script&gt;')
    expect(public_ip_response.body).not_to include('<script>address()</script>')
  end

  it 'shows normalized loop frequency and Proton gateway defaults on the About page' do
    ENV['LOOP_FREQ'] = 'invalid'
    ENV['PROTON_GATEWAY'] = ''

    response = web_request.get('/about')

    expect(response.body).to include('LOOP_FREQ: 45', 'PROTON_GATEWAY: 10.2.0.1')
  end

  it 'renders logs' do
    allow_any_instance_of(Service::Helpers).to receive(:log_lines_to_a).and_return(['log line'])

    response = web_request.get('/logs')

    expect(response.status).to eq(200)
    expect(response.body).to include('log line')
  end

  it 'renders complete live pages without requiring HTMX request headers' do
    { '/' => 'status', '/history' => 'history', '/logs' => 'logs' }.each do |path, region|
      response = web_request.get(path)

      expect(response.status).to eq(200)
      expect(response.body).to include('<!doctype html>', '/js/vendor/htmx-2.0.10.min.js')
      expect(response.body.scan('sse-connect="/events"').length).to eq(1)
      trigger = region == 'logs' ? 'sse:refresh' : "sse:#{region}_changed, sse:refresh"
      expect(response.body).to include("hx-trigger=\"#{trigger}\"")
      expect(response.body).not_to include('http-equiv="refresh"', 'name="refresh"', 'window.location.reload')
    end
    expect(web_request.get('/about').body).not_to include('sse-connect=')
  end

  it 'renders current status and synchronization progress as an uncached partial' do
    transition = PortTransition.record_transition(
      previous_port: 11_111, new_port: 12_345, opnsense_skipped: false, qbit_skipped: false
    )
    pending = web_request.get('/partials/status')
    expect(pending.body.scan('sync: pending').length).to eq(2)

    PortTransition.mark_synced('opnsense', transition.new_port)
    response = web_request.get('/partials/status')
    expect(response.status).to eq(200)
    expect(response['cache-control']).to eq('no-store')
    expect(response.body).to include('current port: 12345', 'sync: synced', 'sync: pending')
    expect(response.body).not_to include('<!doctype', '<script', 'terminal-nav', '<form')

    PortTransition.mark_error('qbit', transition.new_port)
    expect(web_request.get('/partials/status').body).to include('sync: error')
    PortTransition.mark_synced('qbit', transition.new_port)
    expect(web_request.get('/partials/status').body.scan('sync: synced').length).to eq(2)
  end

  it 'keeps log count and ordering in live requests and escapes logged HTML' do
    allow_any_instance_of(Service::Helpers).to receive(:log_lines_to_a).with(500, true)
                                                                       .and_return(['<script>alert(1)</script>'])
    page = web_request.get('/logs?lines=500&direction=desc')
    expect(page.body).to include('hx-get="/partials/logs?lines=500&amp;direction=desc"')
    log_changes = page.body[/<div hidden[^>]*>/m]
    log_region = page.body[/<div id="logs"[^>]*>/m]
    # Reset the delay on each event so the refresh includes the final writes in a burst.
    expect(log_changes).to include('hx-trigger="sse:logs_changed delay:500ms"', 'hx-target="#logs"')
    expect(log_region).to include('hx-trigger="sse:refresh"')
    expect(log_region).not_to include('delay:', 'throttle:')
    expect(page.body).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
    expect(page.body.index('<form')).to be < page.body.index('id="logs"')

    allow_any_instance_of(Service::Helpers).to receive(:log_lines_to_a).with(500, false).and_return(['oldest'])
    partial = web_request.get('/partials/logs?lines=500&direction=asc')
    expect(partial.status).to eq(200)
    expect(partial['cache-control']).to eq('no-store')
    expect(partial.body).to include('last 500 lines of log output, oldest first', 'oldest')
    expect(partial.body).not_to include('<!doctype', '<form')
  end

  it 'keeps the selected history page and page size when records change' do
    60.times do |index|
      PortTransition.record_transition(
        previous_port: index + 10_000, new_port: index + 10_001,
        opnsense_skipped: false, qbit_skipped: false, detected_at: Time.at(index)
      )
    end
    page = web_request.get('/history?page=2&per_page=50')
    expect(page.body).to include('hx-get="/partials/history?page=2&amp;per_page=50"')
    expect(page.body.index('<form')).to be < page.body.index('id="history"')

    PortTransition.record_transition(
      previous_port: 10_060, new_port: 10_061, opnsense_skipped: false, qbit_skipped: false
    )
    partial = web_request.get('/partials/history?page=2&per_page=50')
    expect(partial.status).to eq(200)
    expect(partial['cache-control']).to eq('no-store')
    expect(partial.body).to include('showing 51&ndash;61 of 61', 'page 2 of 2', '/history?page=1&per_page=50')
    expect(partial.body).not_to include('<!doctype', '<form', 'refresh=')
  end

  it 'returns a retryable response at the SSE subscriber limit' do
    allow(Framework::Events).to receive(:subscribe).and_return(nil)
    response = web_request.get('/events')

    expect(response.status).to eq(503)
    expect(response['retry-after']).to eq('3')
  end

  it 'does not subscribe on a HEAD request' do
    expect(Framework::Events).not_to receive(:subscribe)
    expect(web_request.head('/events').status).to eq(200)
  end

  it 'renders logs with query string controls' do
    expect_any_instance_of(Service::Helpers).to receive(:log_lines_to_a).with(500, true).and_return(['new log'])

    response = web_request.get('/logs?lines=500&direction=desc&refresh=5')

    expect(response.status).to eq(200)
    expect(response.body).to include('new log')
    expect(response.body).not_to include('http-equiv="refresh"', 'auto-refresh', 'name="refresh"')
    expect(response.body).to include('last 500 lines of log output, newest first')
  end

  it 'renders an empty port transition history' do
    response = web_request.get('/history')

    expect(response.status).to eq(200)
    expect(response.body).to include('port transition history')
    expect(response.body).to include('no port transitions have been recorded yet')
  end

  it 'renders paginated port transitions with familiar controls' do
    30.times do |index|
      PortTransition.record_transition(
        previous_port: index + 10_000,
        new_port: index + 10_001,
        opnsense_skipped: false,
        qbit_skipped: index.zero?,
        detected_at: Time.at(index)
      )
    end

    response = web_request.get('/history?page=2&per_page=25&refresh=5')

    expect(response.status).to eq(200)
    expect(response.body).to include('showing 26&ndash;30 of 30 transitions, newest first')
    expect(response.body).to include('page 2 of 2')
    expect(response.body).to include('previous')
    expect(response.body).to include(
      '<span class="pagination-current" aria-current="page"><span aria-hidden="true">[</span>2' \
      '<span aria-hidden="true">]</span></span>'
    )
    expect(response.body).to include('<a class="pagination-link" href="/history?page=1')
    expect(response.body).to include('skipped')
    expect(response.body).to include('value="25" selected')
    expect(response.body).not_to include('http-equiv="refresh"', 'auto-refresh', 'name="refresh"')
    expect(response.body).to include('/history?page=1&per_page=25')
    expect(response.body).to include('hx-get="/partials/history?page=2&amp;per_page=25"')
  end

  it 'renders successful timestamps without redundant status text and labels other states' do
    synced = PortTransition.record_transition(
      previous_port: 12_345, new_port: 23_456, opnsense_skipped: false, qbit_skipped: false
    )
    errored = PortTransition.record_transition(
      previous_port: 23_456, new_port: 34_567, opnsense_skipped: false, qbit_skipped: false
    )
    mixed = PortTransition.record_transition(
      previous_port: 34_567, new_port: 45_678, opnsense_skipped: false, qbit_skipped: false
    )
    PortTransition.record_transition(
      previous_port: 45_678, new_port: 56_789, opnsense_skipped: true, qbit_skipped: true
    )
    PortTransition.mark_synced('opnsense', synced.new_port, at: Time.at(10))
    PortTransition.mark_synced('qbit', synced.new_port, at: Time.at(11))
    PortTransition.mark_error('opnsense', errored.new_port, at: Time.at(12))
    PortTransition.mark_synced('opnsense', mixed.new_port, at: Time.at(13))
    PortTransition.mark_error('qbit', mixed.new_port, at: Time.at(14))

    response = web_request.get('/history')

    expect(response.body).to include("<td>#{synced.refresh.opnsense_synced_at}</td>")
    expect(response.body).to include("<td>#{synced.qbit_synced_at}</td>")
    expect(response.body).to include('<td>pending</td>', '<td>error</td>', '<td>skipped</td>')
    expect(response.body).not_to match(%r{<td>\s*synced\s*</td>})
  end

  it 'constrains invalid history pagination parameters' do
    PortTransition.record_transition(
      previous_port: 12_345,
      new_port: 23_456,
      opnsense_skipped: false,
      qbit_skipped: false
    )

    response = web_request.get('/history?page=999&per_page=500')

    expect(response.status).to eq(200)
    expect(response.body).to include('showing 1&ndash;1 of 1 transitions')
    expect(response.body).to include('page 1 of 1')
    expect(response.body).to include('value="25" selected')
  end

  it 'windows long pagination while keeping nearby, first, and last pages' do
    500.times do |index|
      PortTransition.create(
        previous_port: index + 10_000,
        new_port: index + 10_001,
        detected_at: Time.at(index),
        opnsense_skipped: false,
        qbit_skipped: false
      )
    end

    response = web_request.get('/history?page=10&per_page=25')

    expect(response.status).to eq(200)
    expect(response.body.scan('class="pagination-gap"').length).to eq(2)
    expect(response.body).to include('href="/history?page=1&', 'href="/history?page=8&', 'href="/history?page=9&')
    expect(response.body).to include('href="/history?page=11&', 'href="/history?page=12&', 'href="/history?page=20&')
    expect(response.body).to include(
      '<span class="pagination-current" aria-current="page"><span aria-hidden="true">[</span>10' \
      '<span aria-hidden="true">]</span></span>'
    )
    expect(response.body).not_to include('href="/history?page=7&', 'href="/history?page=13&')
  end
end
