require 'digest'
require 'rack/utils'
require 'securerandom'

class ApiKey < Sequel::Model # rubocop:disable Style/Documentation
  TOKEN_BYTES = 32
  TOKEN_PREFIX = 'qbop_'.freeze
  TOKEN_PATTERN = /\A#{Regexp.escape(TOKEN_PREFIX)}[0-9a-f]{#{TOKEN_BYTES * 2}}\z/
  DISPLAY_CHARACTERS = 8
  MAX_NAME_LENGTH = 100
  IssuedKey = Data.define(:api_key, :token)
  InvalidName = Class.new(ArgumentError)

  def self.issue(name, now: Time.now)
    name = normalize_name(name)
    token = "#{TOKEN_PREFIX}#{SecureRandom.hex(TOKEN_BYTES)}"
    api_key = create(
      name: name,
      token_digest: digest(token),
      token_prefix: token[0, TOKEN_PREFIX.length + DISPLAY_CHARACTERS],
      created_at: now
    )

    IssuedKey.new(api_key: api_key, token: token)
  end

  def self.authenticate(token, now: Time.now)
    return unless token.is_a?(String) && token.match?(TOKEN_PATTERN)

    token_digest = digest(token)
    api_key = first(token_digest: token_digest)
    return unless api_key && Rack::Utils.secure_compare(api_key.token_digest, token_digest)

    updated = where(id: api_key.id).update(last_used_at: now)
    api_key if updated == 1
  end

  def self.normalize_name(name)
    name = name.to_s.strip
    raise InvalidName, 'name is required' if name.empty?
    raise InvalidName, "name cannot exceed #{MAX_NAME_LENGTH} characters" if name.length > MAX_NAME_LENGTH

    name
  end
  private_class_method :normalize_name

  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end
  private_class_method :digest
end
