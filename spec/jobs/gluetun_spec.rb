require 'bundler/setup'
Bundler.require(:default)
require 'webmock/rspec'
require 'stringio'

require_relative '../support/database_helper'
require_relative '../../service/seed'
require_relative '../../service/opnsense'
require_relative '../../service/qbit'
require_relative '../../jobs/qbop'

RSpec.describe 'Gluetun job synchronization' do # rubocop:disable Metrics/BlockLength
  let(:logger) { instance_double(Logger, info: nil, error: nil) }
  let(:helpers) { Service::Helpers.new }
  let(:config) do
    helpers.env_variables.merge(
      port_source: 'gluetun', gluetun_addr: 'http://gluetun:8000', gluetun_api_key: nil,
      gluetun_user: nil, gluetun_pass: nil, required_attempts: 2, opnsense_skip: 'false', qbit_skip: 'false'
    )
  end
  let(:job) { Qbop.allocate }
  let(:opnsense) do
    instance_double(Service::Opnsense, get_alias_uuid: 'alias-uuid', get_alias_value: 22_222,
                                       set_alias_value: nil, apply_changes: double(status: 200))
  end
  let(:qbit) do
    instance_double(Service::Qbit, qbt_app_preferences: 22_222, qbt_app_set_preferences: double(status: 200))
  end

  before do
    SpecDatabase.reset!
    # Evaluate the configuration before stubbing the helper to avoid recursive evaluation.
    settings = config
    allow(helpers).to receive_messages(env_variables: settings, logger_instance: logger)
    allow(Service::Helpers).to receive(:new).and_return(helpers)
    Service::Seed.new
    %w[gluetun proton opnsense qbit].each do |name|
      source = Source.find_or_create(name: name)
      source.seed_tables
      source.set_current_port(22_222)
      source.set_last_checked
      source.set_updated_at
    end
    allow(Service::Opnsense).to receive(:new).and_return(opnsense)
    allow(Service::Qbit).to receive(:new).and_return(qbit)
    allow(job).to receive(:sleep)
    job.send(:initialize_dependencies)
    expect(Open3).not_to receive(:capture3)
  end

  it 'uses Gluetun state and preserves confirmation before synchronizing both integrations' do
    proton_state = Source[name: 'proton'].stat.values
    proton_transition = PortTransition.record_transition(
      previous_port: 12_345, new_port: 80, opnsense_skipped: false, qbit_skipped: false
    )
    stub_request(:get, 'http://gluetun:8000/v1/portforward').to_return(body: '{"port":80}')

    job.send(:run_loop_iteration)

    expect(Source[name: 'gluetun'].get_current_port).to eq(80)
    expect(Source[name: 'qbit'].attempt).to eq(1)
    expect(Source[name: 'opnsense'].attempt).to eq(1)
    expect(qbit).not_to have_received(:qbt_app_set_preferences)
    expect(opnsense).not_to have_received(:set_alias_value)

    job.send(:run_loop_iteration)

    expect(qbit).to have_received(:qbt_app_set_preferences).with(80).once
    expect(opnsense).to have_received(:set_alias_value).with(80, 'alias-uuid').once
    expect(opnsense).to have_received(:apply_changes).once
    transition = PortTransition.where(source_name: 'gluetun').first
    expect(transition.previous_port).to eq(22_222)
    expect(transition.sync_status('opnsense')).to eq('synced')
    expect(transition.sync_status('qbit')).to eq('synced')
    expect(PortTransition.where(source_name: 'gluetun').count).to eq(1)
    expect(proton_transition.refresh.sync_status('qbit')).to eq('pending')
    expect(Source[name: 'proton'].stat.values).to eq(proton_state)
    expect(logger).to have_received(:info).with('Gluetun returned the new forwarded port 80')
  end

  [
    { status: 500 }, { status: 401 }, { status: 403 }, { body: '{"port":0}' },
    { body: '{"port":null}' }, { body: 'malformed' }, { error: Faraday::TimeoutError },
    { error: Faraday::ConnectionFailed }
  ].each do |failure|
    it "preserves all state and performs no downstream reads or writes on source failure #{failure}" do
      request = stub_request(:get, 'http://gluetun:8000/v1/portforward')
      failure[:error] ? request.to_raise(failure[:error]) : request.to_return(failure)
      stats_before = DB[:stats].order(:id).all
      counters_before = DB[:counters].order(:id).all

      job.send(:run_loop_iteration)

      expect(DB[:stats].order(:id).all).to eq(stats_before)
      expect(DB[:counters].order(:id).all).to eq(counters_before)
      expect(PortTransition.count).to eq(0)
      expect(qbit).not_to have_received(:qbt_app_preferences)
      expect(qbit).not_to have_received(:qbt_app_set_preferences)
      expect(opnsense).not_to have_received(:get_alias_uuid)
      expect(opnsense).not_to have_received(:set_alias_value)
      expect(opnsense).not_to have_received(:apply_changes)
      expect(logger).to have_received(:error).with('Gluetun has returned an error:')
      expect(job).to have_received(:sleep).with(config[:loop_freq])
    end
  end

  it 'recovers on later loop iterations after a temporary source failure' do
    stub_request(:get, 'http://gluetun:8000/v1/portforward')
      .to_return(status: 500).then.to_return(body: '{"port":51820}')

    3.times { job.send(:run_loop_iteration) }

    expect(Source[name: 'gluetun'].get_current_port).to eq(51_820)
    expect(qbit).to have_received(:qbt_app_set_preferences).with(51_820).once
    expect(opnsense).to have_received(:set_alias_value).with(51_820, 'alias-uuid').once
  end

  it 'preserves pending target work and old synced history throughout a control server outage' do
    old_history = PortTransition.record_transition(
      previous_port: 12_345, new_port: 22_222, source_name: 'gluetun',
      opnsense_skipped: false, qbit_skipped: false
    )
    PortTransition.mark_synced('opnsense', 22_222, source_name: 'gluetun')
    pending = PortTransition.record_transition(
      previous_port: 34_567, new_port: 22_222, source_name: 'proton',
      opnsense_skipped: false, qbit_skipped: false
    )
    PortTransition.mark_error('opnsense', 22_222, source_name: 'proton')
    target = Source[name: 'opnsense']
    target.set_current_port(34_567)
    target.set_pending_apply(22_222, [pending.id])
    state_before = target.counter.values.dup
    history_before = old_history.refresh.values.dup
    stub_request(:get, 'http://gluetun:8000/v1/portforward').to_return(status: 500)

    job.send(:run_loop_iteration)

    expect(target.counter.refresh.values).to eq(state_before)
    expect(old_history.refresh.values).to eq(history_before)
    expect(target.get_current_port).to eq(34_567)
    expect(opnsense).not_to have_received(:apply_changes)
    expect(qbit).not_to have_received(:qbt_app_preferences)
  end

  [Faraday::ConnectionFailed, ArgumentError].each do |error|
    it "keeps #{error} credentials out of the actual formatted job log" do
      output = StringIO.new
      job.instance_variable_set(:@logger, Logger.new(output))
      stub_request(:get, 'http://gluetun:8000/v1/portforward')
        .to_raise(error.new('api-secret user-secret pass-secret http://url-user:url-secret@gluetun:8000'))

      job.send(:run_loop_iteration)

      expect(output.string).to include("Gluetun control API request failed (#{error})")
      expect(output.string).not_to include('api-secret', 'user-secret', 'pass-secret', 'url-user', 'url-secret')
      expect(qbit).not_to have_received(:qbt_app_set_preferences)
      expect(opnsense).not_to have_received(:set_alias_value)
    end
  end

  [
    [{ gluetun_api_key: "api-secret\nsuffix" }, 'GLUETUN_API_KEY'],
    [{ gluetun_user: "user-secret\u0001", gluetun_pass: 'pass-secret' }, 'GLUETUN_USER'],
    [{ gluetun_user: 'user-secret', gluetun_pass: "pass-secret\r\nsuffix" }, 'GLUETUN_PASS'],
    [{ gluetun_user: "user-secret\nsuffix", gluetun_pass: nil }, 'must both be configured for Basic authentication'],
    [{ gluetun_user: nil, gluetun_pass: "pass-secret\0suffix" }, 'must both be configured for Basic authentication'],
    [{ gluetun_addr: 'http://url-user:url-secret@gluetun:8000/bad path' }, 'URI::InvalidURIError'],
    [{ gluetun_addr: 'http://url-user:url-secret@gluetun:0/control' }, 'port must be in 1-65535'],
    [{ gluetun_addr: 'http://url-user:url-secret@gluetun:65536/control' }, 'port must be in 1-65535'],
    [{ gluetun_addr: 'http://url-user:url-secret@gluetun:8000?api_key=query-secret' }, 'query string or fragment'],
    [{ gluetun_addr: 'http://url-user:url-secret@gluetun:8000#fragment-secret' }, 'query string or fragment']
  ].each do |invalid_settings, diagnostic|
    it "keeps invalid #{invalid_settings.keys.first} secrets out of SuckerPunch startup logs: #{diagnostic}" do
      output = StringIO.new
      config.merge!(invalid_settings)
      allow(Qbop).to receive(:new).and_return(job)
      allow(SuckerPunch).to receive(:logger).and_return(Logger.new(output))
      expect(job).not_to receive(:run_loop_iteration)

      Qbop.__run_perform

      expect(output.string).to include('Service::Gluetun::PortError', diagnostic)
      expect(output.string).not_to include('api-secret', 'user-secret', 'pass-secret', 'url-user', 'url-secret',
                                           'query-secret', 'fragment-secret')
      expect(qbit).not_to have_received(:qbt_app_preferences)
      expect(opnsense).not_to have_received(:get_alias_uuid)
    end
  end
end
