require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'
require_relative '../../service/settings'
require_relative '../../service/port_source'

RSpec.describe Service::Settings do # rubocop:disable Metrics/BlockLength
  let(:environment) { {} }
  let(:settings) { described_class.new(environment: environment) }

  before { SpecDatabase.reset! }

  {
    loop_freq: [45, '60', 60, '30', 30],
    required_attempts: [3, '7', 7, '2', 2],
    port_source: %w[proton gluetun gluetun proton proton],
    proton_gateway: ['10.2.0.1', '10.7.0.1', '10.7.0.1', '10.8.0.1', '10.8.0.1']
  }.each do |key, (default, database_input, database_value, environment_input, environment_value)|
    describe key.to_s do # rubocop:disable Metrics/BlockLength
      it 'resolves the existing default without creating a row' do
        expect(settings.resolve(key).to_h).to eq(
          value: default, source: :default, environment_name: nil, environment_override: false
        )
        expect(Setting.count).to eq(0)
      end

      it 'resolves an environment value without importing it' do
        environment[key.to_s.upcase] = environment_input

        expect(settings.resolve(key).to_h).to eq(
          value: environment_value, source: :environment, environment_name: key.to_s.upcase, environment_override: true
        )
        expect(Setting.count).to eq(0)
      end

      it 'resolves a stored database value when the environment key is absent' do
        Setting.create(name: key.to_s, value: database_input)

        expect(settings.resolve(key).to_h).to eq(
          value: database_value, source: :database, environment_name: nil, environment_override: false
        )
      end

      it 'uses an environment value ahead of a stored database value' do
        environment[key.to_s.upcase] = environment_input
        Setting.create(name: key.to_s, value: database_input)

        expect(settings.resolve(key).to_h).to eq(
          value: environment_value, source: :environment, environment_name: key.to_s.upcase, environment_override: true
        )
        expect(Setting[name: key.to_s].value).to eq(database_input)
      end

      it 'retains its resolved value and source until a new resolver is created' do
        Setting.create(name: key.to_s, value: database_input)
        original = settings.resolve(key)
        Setting[name: key.to_s].update(value: environment_input)
        environment[key.to_s.upcase] = environment_input
        expect(Setting).not_to receive(:[])

        expect(settings.resolve(key)).to equal(original)
        expect(settings.value(key)).to eq(database_value)
        expect(described_class.new(environment: environment).resolve(key).to_h)
          .to eq(value: environment_value, source: :environment, environment_name: key.to_s.upcase,
                 environment_override: true)
      end

      next if key == :port_source

      ['', " \t\n"].each do |blank|
        it "treats a #{blank.inspect} environment value as absent" do
          environment[key.to_s.upcase] = blank
          Setting.create(name: key.to_s, value: database_input)

          expect(settings.resolve(key).to_h).to eq(
            value: database_value, source: :database, environment_name: nil, environment_override: false
          )
        end

        it "uses the default for #{blank.inspect} environment input without a stored override" do
          environment[key.to_s.upcase] = blank

          expect(settings.resolve(key).to_h).to eq(
            value: default, source: :default, environment_name: nil, environment_override: false
          )
        end
      end
    end
  end

  describe 'numeric validation' do # rubocop:disable Metrics/BlockLength
    ['', ' ', 'invalid', '-5', '0', '1.5'].each do |input|
      it "normalizes invalid database LOOP_FREQ #{input.inspect} to 45" do
        Setting.create(name: 'loop_freq', value: input)

        expect(settings.resolve(:loop_freq).to_h).to eq(
          value: 45, source: :database, environment_name: nil, environment_override: false
        )
      end
    end

    { '1' => 1, '120' => 120, ' 60 ' => 60 }.each do |input, expected|
      it "preserves positive integer database LOOP_FREQ #{input.inspect}" do
        Setting.create(name: 'loop_freq', value: input)

        expect(settings.value(:loop_freq)).to eq(expected)
      end
    end

    { '1' => 1, '10' => 10, '5abc' => 5, '1.5' => 1, '' => 3, ' ' => 3,
      'invalid' => 3, '-1' => 3, '0' => 3, '11' => 3 }.each do |input, expected|
      it "preserves existing REQUIRED_ATTEMPTS validation for database value #{input.inspect}" do
        Setting.create(name: 'required_attempts', value: input)

        expect(settings.resolve(:required_attempts).to_h).to eq(
          value: expected, source: :database, environment_name: nil, environment_override: false
        )
      end
    end

    { loop_freq: ['60', 45], required_attempts: ['7', 3] }.each do |key, (database_value, default)|
      it "normalizes invalid environment #{key} without falling through to a valid database value" do
        environment[key.to_s.upcase] = 'invalid'
        Setting.create(name: key.to_s, value: database_value)

        expect(settings.resolve(key).to_h).to eq(
          value: default, source: :environment, environment_name: key.to_s.upcase, environment_override: true
        )
      end
    end
  end

  describe 'PORT_SOURCE validation' do
    ['', ' ', 'unsupported', 'PROTON'].each do |input|
      it "keeps environment input #{input.inspect} authoritative and invalid despite a valid DB source" do
        environment['PORT_SOURCE'] = input
        Setting.create(name: 'port_source', value: 'gluetun')

        expect(settings.resolve(:port_source).to_h).to eq(
          value: input, source: :environment, environment_name: 'PORT_SOURCE', environment_override: true
        )
        expect(settings.resolve(:port_source).environment_override?).to be(true)
        expect { Service::PortSource.name(port_source: settings.value(:port_source)) }
          .to raise_error(Service::PortSource::ConfigurationError, 'PORT_SOURCE must be proton or gluetun')
      end
    end

    it 'leaves invalid database source values subject to the same validation' do
      Setting.create(name: 'port_source', value: '')

      expect { Service::PortSource.name(port_source: settings.value(:port_source)) }
        .to raise_error(Service::PortSource::ConfigurationError, 'PORT_SOURCE must be proton or gluetun')
    end
  end

  it 'does not expose or resolve unsupported settings, including browser authentication' do
    Setting.create(name: 'unrelated_setting', value: 'unrelated-value')

    expect { settings.resolve(:oidc_client_secret) }.to raise_error(KeyError)
    expect { settings.resolve(:unrelated_setting) }.to raise_error(KeyError)
    expect(settings.resolve(:loop_freq).to_h.keys)
      .to contain_exactly(:value, :source, :environment_name, :environment_override)
  end
end
