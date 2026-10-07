require 'bundler/setup'
Bundler.require(:default)
require 'tmpdir'
require_relative '../../service/settings_encryption_key'

RSpec.describe Service::SettingsEncryptionKey do # rubocop:disable Metrics/BlockLength
  let(:key_path) { File.join(@directory, 'settings_encryption_key.txt') }
  let(:key) { described_class.new(path: key_path) }

  around do |example|
    Dir.mktmpdir('qbop-key') do |directory|
      @directory = directory
      example.run
    end
  end

  it 'creates independent 256-bit material with private permissions and reloads it unchanged' do
    material = key.load_or_create { false }
    encoded = File.read(key_path)

    expect(material.bytesize).to eq(32)
    expect(encoded).to match(/\A[0-9a-f]{64}\z/)
    expect(File.stat(key_path).mode & 0o777).to eq(0o600)
    expect(File.stat("#{key_path}.lock").mode & 0o777).to eq(0o600)
    expect(SecureRandom).not_to receive(:hex)
    expect(described_class.new(path: key_path).load).to eq(material)
    expect(key.load_or_create { true }).to eq(material)
    expect(File.read(key_path)).to eq(encoded)
  end

  it 'tightens existing key permissions when loaded' do
    key.load_or_create { false }
    File.chmod(0o644, key_path)

    key.load

    expect(File.stat(key_path).mode & 0o777).to eq(0o600)
  end

  it 'requires the original missing key for reads and writes with dependent encrypted rows' do
    [-> { key.load }, -> { key.load_or_create { true } }].each do |operation|
      expect(&operation).to raise_error(described_class::ConfigurationError, /key is missing/) { |error|
        expect(error.cause).to be_nil
      }
      expect(File.exist?(key_path)).to be(false)
    end
  end

  ['', 'key-material-private', 'a' * 63, 'a' * 65, 'g' * 64, "#{'a' * 64}\n", "\xFF"].each do |encoded|
    it "rejects malformed existing keys of #{encoded.bytesize} bytes without overwriting them" do
      File.binwrite(key_path, encoded)

      [-> { key.load }, -> { key.load_or_create { false } }].each do |operation|
        expect(&operation).to raise_error(described_class::ConfigurationError, /key is invalid/) { |error|
          expect(error.cause).to be_nil
          expect(error.full_message).not_to include('key-material-private')
        }
        expect(File.binread(key_path)).to eq(encoded.b)
      end
    end
  end

  it 'sanitizes filesystem failures and their causes' do
    key = described_class.new(path: File.join(@directory, 'missing-private-directory', 'key.txt'))

    expect { key.load_or_create { false } }.to raise_error(described_class::ConfigurationError) { |error|
      expect(error.cause).to be_nil
      expect(error.full_message).not_to include('missing-private-directory')
    }
  end

  it 'serializes concurrent first creation and reads so every caller gets the same complete key' do
    gate = Queue.new
    callers = Array.new(12) do
      Thread.new do
        gate.pop
        described_class.new(path: key_path).load_or_create { false }
      end
    end
    12.times { gate << true }

    material = callers.map(&:value)

    expect(material.uniq.size).to eq(1)
    expect(material.first.bytesize).to eq(32)
    expect(key.load).to eq(material.first)
    expect(File.read(key_path)).to match(/\A[0-9a-f]{64}\z/)
  ensure
    callers&.each(&:join)
  end
end
