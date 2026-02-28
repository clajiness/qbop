module Framework
  # handles loading or creating session secrets for the application
  class SessionSecret
    # loads an existing session secret from a file or creates a new one if the file doesn't exist
    #
    # path - the file path to load the secret from or save the new secret to
    # returns the session secret
    def self.load_or_create(path)
      if File.exist?(path)
        File.read(path).strip
      else
        secret = SecureRandom.hex(64)

        File.open(path, 'w') do |f|
          f.write(secret)
        end

        secret
      end
    end
  end
end
