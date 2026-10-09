require 'base64'
require 'openssl'
require_relative 'settings_encryption_key'

module Service
  # Versioned AES-GCM envelopes authenticate both the secret bytes and their setting identity.
  class SettingsEncryption
    ConfigurationError = SettingsEncryptionKey::ConfigurationError
    PREFIX = 'enc:v1:'.freeze
    IV_BYTES = 12
    TAG_BYTES = 16
    DECRYPTION_ERROR = 'Encrypted database credential could not be authenticated or decoded.'.freeze

    def initialize(key_path: SettingsEncryptionKey::DEFAULT_PATH)
      @key = SettingsEncryptionKey.new(path: key_path)
    end

    def encrypt(name, value, &encrypted_values_present) # rubocop:disable Metrics/AbcSize
      cipher = OpenSSL::Cipher.new('aes-256-gcm').encrypt
      cipher.key = @key.load_or_create(&encrypted_values_present)
      cipher.iv = iv = SecureRandom.random_bytes(IV_BYTES)
      cipher.auth_data = authenticated_data(name)
      # Preserve the original string encoding as well as its exact bytes, inside the authenticated envelope.
      plaintext = "#{value.encoding.name}\0".b + value.b
      ciphertext = cipher.update(plaintext) + cipher.final
      PREFIX + Base64.strict_encode64(iv + cipher.auth_tag(TAG_BYTES) + ciphertext)
    rescue OpenSSL::Cipher::CipherError, ArgumentError
      raise ConfigurationError, 'Database credential could not be encrypted.', cause: nil
    end

    def decrypt(name, stored) # rubocop:disable Metrics/AbcSize
      payload = decode_payload(stored)
      cipher = OpenSSL::Cipher.new('aes-256-gcm').decrypt
      cipher.key = @key.load
      cipher.iv = payload.byteslice(0, IV_BYTES)
      cipher.auth_tag = payload.byteslice(IV_BYTES, TAG_BYTES)
      cipher.auth_data = authenticated_data(name)
      plaintext = cipher.update(payload.byteslice(IV_BYTES + TAG_BYTES..)) + cipher.final
      decode_plaintext(plaintext)
    rescue OpenSSL::Cipher::CipherError, ArgumentError, EncodingError
      raise ConfigurationError, DECRYPTION_ERROR, cause: nil
    end

    private

    def authenticated_data(name)
      "qbop:settings:enc:v1:#{name}"
    end

    def decode_payload(stored)
      raise ArgumentError unless stored.is_a?(String) && stored.start_with?(PREFIX)

      payload = Base64.strict_decode64(stored.delete_prefix(PREFIX))
      raise ArgumentError unless payload.bytesize > IV_BYTES + TAG_BYTES

      payload
    end

    def decode_plaintext(plaintext)
      encoding, value = plaintext.split("\0", 2)
      raise ArgumentError unless value

      value.force_encoding(Encoding.find(encoding))
      raise ArgumentError unless value.valid_encoding?

      value
    end
  end
end
