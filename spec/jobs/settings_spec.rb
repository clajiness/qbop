require 'bundler/setup'
Bundler.require(:default)
require 'webmock/rspec'

require_relative '../support/database_helper'
require_relative '../../service/seed'
require_relative '../../service/opnsense'
require_relative '../../service/qbit'
require_relative '../../jobs/qbop'

RSpec.describe 'Qbop settings lifecycle' do # rubocop:disable Metrics/BlockLength
  let(:logger) { instance_double(Logger, info: nil, error: nil) }
  let(:job) { Qbop.allocate }

  around do |example|
    keys = %w[LOOP_FREQ REQUIRED_ATTEMPTS PORT_SOURCE PROTON_GATEWAY GLUETUN_ADDR GLUETUN_API_KEY
              GLUETUN_USER GLUETUN_PASS GLUETUN_SSL_VERIFY OPN_SKIP OPN_INTERFACE_ADDR OPN_SSL_VERIFY
              QBIT_SKIP QBIT_ADDR QBIT_SSL_VERIFY]
    original = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| ENV.delete(key) }
    ENV.update('OPN_SKIP' => 'true', 'QBIT_SKIP' => 'true')
    example.run
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  before do
    SpecDatabase.reset!
    allow_any_instance_of(Service::Helpers).to receive(:logger_instance).and_return(logger)
    allow(job).to receive(:sleep)
  end

  it 'retains startup configuration and clients after explicit integration settings writes and deletes' do # rubocop:disable Metrics/BlockLength
    ENV.delete('OPN_SKIP')
    ENV.delete('QBIT_SKIP')
    settings = Service::Settings.new
    { port_source: 'gluetun', loop_freq: 60, gluetun_addr: 'http://gluetun:8000/control/',
      opnsense_skip: true, opnsense_interface_addr: 'https://firewall/',
      qbit_skip: true, qbit_addr: 'http://qbit:8080/' }.each { |key, value| settings.set(key, value) }
    Service::Seed.new
    [Service::Gluetun, Service::Opnsense, Service::Qbit].each do |client|
      allow(client).to receive(:new).and_call_original
    end
    job.send(:initialize_dependencies)
    original_config = job.instance_variable_get(:@config).dup
    expect(Qbop).not_to receive(:perform_async)
    settings.set(:gluetun_addr, 'http://other-gluetun:8000/')
    settings.set(:opnsense_skip, false)
    settings.set(:qbit_skip, false)
    settings.set(:opnsense_interface_addr, 'https://other-firewall/')
    settings.set(:qbit_addr, 'http://other-qbit:8080/')
    settings.delete(:loop_freq)
    stub_request(:get, 'http://gluetun:8000/control/v1/portforward').to_return(body: '{"port":23456}')

    2.times { job.send(:run_loop_iteration) }

    expect(job.instance_variable_get(:@config)).to eq(original_config)
    [Service::Gluetun, Service::Opnsense, Service::Qbit].each do |client|
      expect(client).to have_received(:new).once
    end
    expect(Source[name: 'gluetun'].get_current_port).to eq(23_456)
    expect(logger).to have_received(:info).with('OPNsense check skipped').twice
    expect(logger).to have_received(:info).with('qBit check skipped').twice
    expect(job).to have_received(:sleep).with(60).twice
  end

  it 'selects and seeds Gluetun from the database and retains startup settings during later iterations' do
    { loop_freq: '60', required_attempts: '7', port_source: 'gluetun', proton_gateway: '10.7.0.1' }
      .each { |name, value| Setting.create(name: name.to_s, value: value) }
    Service::Seed.new
    job.send(:initialize_dependencies)
    original_config = job.instance_variable_get(:@config).dup
    Setting.where(name: 'loop_freq').update(value: '120')
    Setting.where(name: 'required_attempts').update(value: '1')
    Setting.where(name: 'port_source').update(value: 'proton')
    Setting.where(name: 'proton_gateway').update(value: '10.8.0.1')
    stub_request(:get, 'http://gluetun:8000/v1/portforward').to_return(body: '{"port":23456}')
    expect(Setting).not_to receive(:[])
    expect(Open3).not_to receive(:capture3)

    2.times { job.send(:run_loop_iteration) }

    expect(job.instance_variable_get(:@config)).to eq(original_config)
    expect(original_config).to include(
      loop_freq: 60, required_attempts: 7, port_source: 'gluetun', proton_gateway: '10.7.0.1'
    )
    expect(job.instance_variable_get(:@port_source)).to be_a(Service::Gluetun)
    expect(Source[name: 'gluetun'].get_current_port).to eq(23_456)
    expect(Source[name: 'proton']).to be_nil
    expect(job).to have_received(:sleep).with(60).twice
  end

  it 'retains the Proton timeout and gateway from startup even when database settings change' do
    Setting.create(name: 'loop_freq', value: '60')
    Setting.create(name: 'proton_gateway', value: '10.7.0.1')
    Service::Seed.new
    job.send(:initialize_dependencies)
    Setting.where(name: 'loop_freq').update(value: '120')
    Setting.where(name: 'proton_gateway').update(value: '10.8.0.1')
    status = instance_double(Process::Status, success?: true)
    %w[udp tcp].each do |protocol|
      allow(Open3).to receive(:capture3)
        .with('timeout', '55', 'natpmpc', '-a', '1', '0', protocol, '60', '-g', '10.7.0.1')
        .and_return(["Mapped public port 23456 protocol #{protocol.upcase}", '', status])
    end
    expect(Setting).not_to receive(:[])

    2.times { job.send(:run_loop_iteration) }

    expect(Source[name: 'proton'].get_current_port).to eq(23_456)
    expect(Open3).to have_received(:capture3).exactly(4).times
    expect(job).to have_received(:sleep).with(60).twice
  end

  it 'uses an explicit Proton environment selection ahead of a stored Gluetun selection' do
    Setting.create(name: 'port_source', value: 'gluetun')
    ENV['PORT_SOURCE'] = 'proton'
    Service::Seed.new

    job.send(:initialize_dependencies)

    expect(job.instance_variable_get(:@port_source)).to be_a(Service::Proton)
    expect(Source[name: 'proton']).not_to be_nil
    expect(Source[name: 'gluetun']).to be_nil
  end

  it 'does not import environment settings during seed or job initialization' do
    ENV.update('LOOP_FREQ' => '30', 'REQUIRED_ATTEMPTS' => '5', 'PROTON_GATEWAY' => '10.7.0.1',
               'PORT_SOURCE' => 'proton')

    Service::Seed.new
    job.send(:initialize_dependencies)

    expect(job.instance_variable_get(:@config)).to include(
      loop_freq: 30, required_attempts: 5, port_source: 'proton', proton_gateway: '10.7.0.1'
    )
    expect(Setting.count).to eq(0)
  end
end
