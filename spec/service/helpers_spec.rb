require_relative '../../service/helpers'

RSpec.describe Service::Helpers do # rubocop:disable Metrics/BlockLength
  describe '#env_variables' do # rubocop:disable Metrics/BlockLength
    context 'when script_version is set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:script_version]).to eq(nil)
      end
    end
    context 'when loop_freq is set' do
      it 'returns the loop frequency' do
        expect(Service::Helpers.new.env_variables[:loop_freq]).to eq(45)
      end
      it 'does not return nil' do
        expect(Service::Helpers.new.env_variables[:loop_freq]).not_to eq(nil)
      end
    end
    context 'when required_attempts is set' do
      it 'returns the required attempts' do
        expect(Service::Helpers.new.env_variables[:required_attempts]).to eq(3)
      end
      it 'does not return nil' do
        expect(Service::Helpers.new.env_variables[:required_attempts]).not_to eq(nil)
      end
    end
    context 'when proton_gateway is set' do
      it 'returns the proton gateway' do
        expect(Service::Helpers.new.env_variables[:proton_gateway]).to eq('10.2.0.1')
      end
    end
    context 'when opnsense_interface_addr is set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:opnsense_interface_addr]).to eq(nil)
      end
    end
    context 'when opnsense_api_key is set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:opnsense_api_key]).to eq(nil)
      end
    end
    context 'when opnsense_api_secret is set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:opnsense_api_secret]).to eq(nil)
      end
    end
    context 'when opnsense_alias_name is set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:opnsense_alias_name]).to eq(nil)
      end
    end
    context 'when qbit_skip is set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:qbit_skip]).to eq(nil)
      end
    end
    context 'when qbit_addr is set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:qbit_addr]).to eq(nil)
      end
    end
    context 'when qbit_user is set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:qbit_user]).to eq(nil)
      end
    end
    context 'when qbit_pass is set' do
      it 'returns nil' do
        expect(Service::Helpers.new.env_variables[:qbit_pass]).to eq(nil)
      end
    end
  end

  describe '#parse_loop_frequency' do
    it 'returns the argument if it is a positive integer' do
      expect(Service::Helpers.new.parse_loop_frequency(45)).to eq(45)
    end
    it 'returns the argument if it is a negative integer' do
      expect(Service::Helpers.new.parse_loop_frequency(-45)).to eq(45)
    end
    it 'returns nil if the argument is 0' do
      expect(Service::Helpers.new.parse_loop_frequency(0)).to eq(45)
    end
    it 'returns nil if the argument is nil' do
      expect(Service::Helpers.new.parse_loop_frequency(nil)).to eq(45)
    end
  end

  describe '#skip_qbit?' do
    it 'returns true if the argument is true' do
      expect(Service::Helpers.new.skip_qbit?(true)).to eq(true)
    end
    it 'returns true if the argument is the string true' do
      expect(Service::Helpers.new.skip_qbit?('true')).to eq(true)
    end
    it 'returns false if the argument is false' do
      expect(Service::Helpers.new.skip_qbit?(false)).to eq(false)
    end
    it 'returns false if the argument is the string false' do
      expect(Service::Helpers.new.skip_qbit?('false')).to eq(false)
    end
    it 'returns false if the argument is a random string' do
      expect(Service::Helpers.new.skip_qbit?('abcd123')).to eq(false)
    end
    it 'returns false if the argument is nil' do
      expect(Service::Helpers.new.skip_qbit?(nil)).to eq(false)
    end
  end
end
