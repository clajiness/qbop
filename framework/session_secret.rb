require 'securerandom'

module Framework
  # handles loading or creating session secrets for the application
  class SessionSecret
    MINIMUM_BYTES = 64

    # loads an existing session secret from a file or creates a new one if the file doesn't exist
    #
    # path - the file path to load the secret from or save the new secret to
    # returns the session secret
    def self.load_or_create(path)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.chmod(0o600)

        secret = file.read.strip
        return validate(secret) unless secret.empty?

        create(file)
      end
    end

    def self.create(file)
      secret = SecureRandom.hex(64)
      file.rewind
      file.write(secret)
      file.truncate(file.pos)
      file.flush
      secret
    end
    private_class_method :create

    def self.validate(secret)
      return secret if secret.bytesize >= MINIMUM_BYTES

      raise ArgumentError, "session secret must contain at least #{MINIMUM_BYTES} bytes"
    end
    private_class_method :validate
  end
end
