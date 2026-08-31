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

  around do |example|
    version = ENV['VERSION']
    commit_sha = ENV['COMMIT_SHA']
    build_date = ENV['BUILD_DATE']
    web_auth_enabled = ENV['WEB_AUTH_ENABLED']
    opnsense_skip = ENV['OPN_SKIP']
    ENV.delete('VERSION')
    ENV.delete('COMMIT_SHA')
    ENV.delete('BUILD_DATE')
    ENV.delete('OPN_SKIP')
    ENV['WEB_AUTH_ENABLED'] = 'false'
    example.run
  ensure
    version.nil? ? ENV.delete('VERSION') : ENV['VERSION'] = version
    commit_sha.nil? ? ENV.delete('COMMIT_SHA') : ENV['COMMIT_SHA'] = commit_sha
    build_date.nil? ? ENV.delete('BUILD_DATE') : ENV['BUILD_DATE'] = build_date
    web_auth_enabled.nil? ? ENV.delete('WEB_AUTH_ENABLED') : ENV['WEB_AUTH_ENABLED'] = web_auth_enabled
    opnsense_skip.nil? ? ENV.delete('OPN_SKIP') : ENV['OPN_SKIP'] = opnsense_skip
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

  it 'renders the stats page with meta refresh when requested' do
    response = web_request.get('/?refresh=5')

    expect(response.status).to eq(200)
    expect(response.body).to include('<meta http-equiv="refresh" content="5" />')
  end

  it 'renders update notification details when present' do
    ENV['VERSION'] = 'v2.6.0'
    Notification.create(name: 'update_available', info: 'v2.7.0', active: true)

    response = web_request.get('/about')

    expect(response.status).to eq(200)
    expect(response.body).to include('v2.7.0')
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
      "Uses proton's server identifier to generate a name such as",
      '<code>Proton_US-IL661</code>'
    )
    checkbox = response.body[/<input[^>]+id="wireguardrenamepeer"[^>]*>/]
    expect(checkbox).not_to include('disabled', 'checked')
    expect(response.body).not_to include(
      'protonPeerName', 'FileReader', 'wireguardrenamepeerlabel',
      'reload Tools to use the WireGuard importer'
    )
  end

  it 'keeps the tools page available without loading WireGuard targets when OPNsense is skipped' do
    ENV['OPN_SKIP'] = 'true'
    expect_any_instance_of(Service::Opnsense).not_to receive(:wireguard_targets)

    response = web_request.get('/tools')

    expect(response.status).to eq(200)
    expect(response.body).to include(
      'Proton WireGuard import requires OPNsense integration.',
      'generate wireguard public key',
      'get public ip address'
    )
    expect(response.body).not_to include('id="wgimportform"')
    expect(response.body).not_to include('reload Tools to use the WireGuard importer')
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
    expect(response.body).to include('Proton WireGuard import requires OPNsense integration.')
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
    expect(response.body).not_to include('reload Tools to use the WireGuard importer')
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
    expect(response.body).to include('href="/tools">reload Tools to use the WireGuard importer</a>')
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
    expect(public_key_response.body).to include('Proton WireGuard import requires OPNsense integration.')
    expect(public_key_response.body).not_to include('reload Tools to use the WireGuard importer')
    expect(public_ip_response.status).to eq(200)
    expect(public_ip_response.body).to include('akamai -> 192.0.2.1')
    expect(public_ip_response.body).to include('Proton WireGuard import requires OPNsense integration.')
    expect(public_ip_response.body).not_to include('reload Tools to use the WireGuard importer')
  end

  it 'renders public IP tool results without loading WireGuard targets' do
    expect(Service::Opnsense).not_to receive(:new)
    allow_any_instance_of(Service::Helpers).to receive(:get_public_ip).and_return('192.0.2.1')

    response = web_request.post('/public-ip', input: 'select=akamai')

    expect(response.status).to eq(200)
    expect(response.body).to include('akamai -> 192.0.2.1')
    expect(response.body).to include('href="/tools">reload Tools to use the WireGuard importer</a>')
    expect(response.body).not_to include('could not load OPNsense WireGuard targets')
  end

  it 'renders logs' do
    allow_any_instance_of(Service::Helpers).to receive(:log_lines_to_a).and_return(['log line'])

    response = web_request.get('/logs')

    expect(response.status).to eq(200)
    expect(response.body).to include('log line')
  end

  it 'renders logs with query string controls' do
    expect_any_instance_of(Service::Helpers).to receive(:log_lines_to_a).with(500, true).and_return(['new log'])

    response = web_request.get('/logs?lines=500&direction=desc&refresh=5')

    expect(response.status).to eq(200)
    expect(response.body).to include('new log')
    expect(response.body).to include('<meta http-equiv="refresh" content="5" />')
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
    expect(response.body).to include('<meta http-equiv="refresh" content="5" />')
    expect(response.body).to include('/history?page=1&per_page=25&refresh=5')
    expect(response.body).to include('/history?page=2&per_page=25&refresh=0')
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
