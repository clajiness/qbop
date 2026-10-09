require 'securerandom'

module Service
  # Independent, persistent key; a stable lock also protects the first file creation.
  class SettingsEncryptionKey
    DEFAULT_PATH = 'data/settings_encryption_key.txt'.freeze
    KEY_BYTES = 32

    class ConfigurationError < StandardError; end

    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    def load
      with_lock { read }
    end

    # The caller checks for dependent DB rows while the key lifecycle is locked.
    def load_or_create
      with_lock do
        return read if File.exist?(@path)

        missing! if yield

        create
      end
    end

    private

    def with_lock
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |file|
        raise IOError unless file.flock(File::LOCK_EX)

        file.chmod(0o600)
        yield
      end
    rescue SystemCallError, IOError
      raise ConfigurationError, 'Settings encryption key could not be read or written.', cause: nil
    end

    def read
      missing! unless File.exist?(@path)

      encoded = File.open(@path, File::RDONLY) do |file|
        file.chmod(0o600)
        file.binmode.read
      end
      validate(encoded)
    end

    def validate(encoded)
      unless encoded.match?(/\A[0-9a-f]{64}\z/)
        raise ConfigurationError, 'Settings encryption key is invalid; restore the original key.', cause: nil
      end

      [encoded].pack('H*')
    end

    def missing!
      raise ConfigurationError, 'Settings encryption key is missing; restore the original key.', cause: nil
    end

    def create
      encoded = SecureRandom.hex(KEY_BYTES)
      File.open(@path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.chmod(0o600)
        file.write(encoded)
        file.flush
        file.fsync
      end
      [encoded].pack('H*')
    end
  end
end
