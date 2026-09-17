require 'tempfile'
require_relative '../../service/event_logger'

RSpec.describe Service::EventLogger do
  it 'publishes after the file contains the complete log entry' do
    Tempfile.create('qbop-log') do |file|
      logger = described_class.new(file.path)
      expect(Framework::Events).to receive(:publish).with(:logs_changed) do
        expect(File.read(file.path)).to include('a new entry')
      end
      logger.info { 'a new entry' }
      logger.close
    end
  end

  it 'does not publish entries suppressed by the log level' do
    Tempfile.create('qbop-log') do |file|
      logger = described_class.new(file.path, level: Logger::WARN)
      expect(Framework::Events).not_to receive(:publish)
      logger.info('suppressed')
      logger.close
      expect(File.read(file.path)).not_to include('suppressed')
    end
  end
end
