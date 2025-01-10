require_relative '../../service/counter'

RSpec.describe Service::Counter do # rubocop:disable Metrics/BlockLength
  describe '#initialize' do # rubocop:disable Metrics/BlockLength
    context 'when required_attempts is initialized' do
      it 'returns the required attempts' do
        expect(Service::Counter.new.required_attempts).to eq(3)
      end
      it 'does not return 0' do
        expect(Service::Counter.new.required_attempts).not_to eq(0)
      end
      it 'does not return nil' do
        expect(Service::Counter.new.required_attempts).not_to eq(nil)
      end
    end
    context 'when opnsense_attempt is initialized' do
      it 'returns the opnsense attempt' do
        expect(Service::Counter.new.opnsense_attempt).to eq(0)
      end
      it 'does not return 1' do
        expect(Service::Counter.new.opnsense_attempt).not_to eq(1)
      end
      it 'does not return nil' do
        expect(Service::Counter.new.opnsense_attempt).not_to eq(nil)
      end
    end
    context 'when opnsense_change is initialized' do
      it 'returns the opnsense change' do
        expect(Service::Counter.new.opnsense_change).to eq(false)
      end
      it 'does not return true' do
        expect(Service::Counter.new.opnsense_change).not_to eq(true)
      end
      it 'does not return nil' do
        expect(Service::Counter.new.opnsense_change).not_to eq(nil)
      end
    end
    context 'when qbit_attempt is initialized' do
      it 'returns the qbit attempt' do
        expect(Service::Counter.new.qbit_attempt).to eq(0)
      end
      it 'does not return 1' do
        expect(Service::Counter.new.qbit_attempt).not_to eq(1)
      end
      it 'does not return nil' do
        expect(Service::Counter.new.qbit_attempt).not_to eq(nil)
      end
    end
    context 'when qbit_change is initialized' do
      it 'returns the qbit change' do
        expect(Service::Counter.new.qbit_change).to eq(false)
      end
      it 'does not return true' do
        expect(Service::Counter.new.qbit_change).not_to eq(true)
      end
      it 'does not return nil' do
        expect(Service::Counter.new.qbit_change).not_to eq(nil)
      end
    end
  end

  describe '#set_required_attempts' do # rubocop:disable Metrics/BlockLength
    it 'sets the required attempts to 5' do
      expect(Service::Counter.new.set_required_attempts(5)).to eq(5)
    end
    it 'sets the required attempts to 5 if 5 is a string' do
      expect(Service::Counter.new.set_required_attempts(5.to_s)).to eq(5)
    end
    it 'does not return 0' do
      expect(Service::Counter.new.set_required_attempts(5)).not_to eq(0)
    end
    it 'does not return nil' do
      expect(Service::Counter.new.set_required_attempts(5)).not_to eq(nil)
    end
    it 'does not set the required attempts to 0' do
      expect(Service::Counter.new.set_required_attempts(0)).not_to eq(0)
    end
    it 'does not set the required attempts to 11' do
      expect(Service::Counter.new.set_required_attempts(11)).not_to eq(11)
    end
    it 'returns default value if the argument is 0' do
      expect(Service::Counter.new.set_required_attempts(0)).to eq(3)
    end
    it 'returns default value if the argument is 11' do
      expect(Service::Counter.new.set_required_attempts(11)).to eq(3)
    end
    it 'returns default value if the argument is nil' do
      expect(Service::Counter.new.set_required_attempts(nil)).to eq(3)
    end
  end

  describe '#increment_opnsense_attempt' do
    it 'increments the current value by 1' do
      expect(Service::Counter.new.increment_opnsense_attempt).to eq(1)
    end
    it 'does not return 0 after running' do
      expect(Service::Counter.new.increment_opnsense_attempt).not_to eq(0)
    end
    it 'does not increment the current value by 2' do
      expect(Service::Counter.new.increment_opnsense_attempt).not_to eq(2)
    end
    it 'does not return nil' do
      expect(Service::Counter.new.increment_opnsense_attempt).not_to eq(nil)
    end
  end

  describe '#increment_qbit_attempt' do
    it 'increments the current value by 1' do
      expect(Service::Counter.new.increment_qbit_attempt).to eq(1)
    end
    it 'does not return 0 after running' do
      expect(Service::Counter.new.increment_qbit_attempt).not_to eq(0)
    end
    it 'does not increment the current value by 2' do
      expect(Service::Counter.new.increment_qbit_attempt).not_to eq(2)
    end
    it 'does not return nil' do
      expect(Service::Counter.new.increment_qbit_attempt).not_to eq(nil)
    end
  end

  describe '#reset_opnsense_attempt' do
    it 'resets the current value to 0' do
      expect(Service::Counter.new.reset_opnsense_attempt).to eq(0)
    end
    it 'does not return 1 after running' do
      expect(Service::Counter.new.reset_opnsense_attempt).not_to eq(1)
    end
    it 'does not return nil' do
      expect(Service::Counter.new.reset_opnsense_attempt).not_to eq(nil)
    end
  end

  describe '#reset_qbit_attempt' do
    it 'resets the current value to 0' do
      expect(Service::Counter.new.reset_qbit_attempt).to eq(0)
    end
    it 'does not return 1 after running' do
      expect(Service::Counter.new.reset_qbit_attempt).not_to eq(1)
    end
    it 'does not return nil' do
      expect(Service::Counter.new.reset_qbit_attempt).not_to eq(nil)
    end
  end

  describe '#change_opnsense' do
    it 'changes the current value to true' do
      expect(Service::Counter.new.change_opnsense).to eq(true)
    end
    it 'does not return false after running' do
      expect(Service::Counter.new.change_opnsense).not_to eq(false)
    end
    it 'does not return nil' do
      expect(Service::Counter.new.change_opnsense).not_to eq(nil)
    end
  end

  describe '#change_qbit' do
    it 'changes the current value to true' do
      expect(Service::Counter.new.change_qbit).to eq(true)
    end
    it 'does not return false after running' do
      expect(Service::Counter.new.change_qbit).not_to eq(false)
    end
    it 'does not return nil' do
      expect(Service::Counter.new.change_qbit).not_to eq(nil)
    end
  end

  describe '#reset_opnsense_change' do
    it 'resets the current value to false' do
      expect(Service::Counter.new.reset_opnsense_change).to eq(false)
    end
    it 'does not return true after running' do
      expect(Service::Counter.new.reset_opnsense_change).not_to eq(true)
    end
    it 'does not return nil' do
      expect(Service::Counter.new.reset_opnsense_change).not_to eq(nil)
    end
  end

  describe '#reset_qbit_change' do
    it 'resets the current value to false' do
      expect(Service::Counter.new.reset_qbit_change).to eq(false)
    end
    it 'does not return true after running' do
      expect(Service::Counter.new.reset_qbit_change).not_to eq(true)
    end
    it 'does not return nil' do
      expect(Service::Counter.new.reset_qbit_change).not_to eq(nil)
    end
  end
end
