require_relative 'gluetun_url'

module Service
  # Strict validation applies only to explicit settings writes, never legacy configuration reads.
  module SettingsValidation
    class ValidationError < StandardError; end

    def self.canonical_value(definition, value)
      case definition.fetch(:write)
      when :integer then integer(definition, value)
      when :boolean then boolean(definition, value)
      when :enum then enum(definition, value)
      when :text then text(definition, value)
      when :url then url(definition, value)
      when :secret then secret(definition, value)
      end
    end

    def self.invalid!(definition, requirement)
      raise ValidationError, "#{definition.fetch(:environment).first} #{requirement}", cause: nil
    end
    private_class_method :invalid!

    def self.integer(definition, value)
      range = definition[:range]
      requirement = range ? "must be a complete integer in #{range}." : 'must be a complete integer greater than 0.'
      input = value.is_a?(String) || value.is_a?(Integer) ? value.to_s.strip : ''
      invalid!(definition, requirement) unless input.match?(/\A[+-]?\d+\z/)
      number = Integer(input, 10)
      invalid!(definition, requirement) unless range ? range.cover?(number) : number.positive?

      number.to_s
    end
    private_class_method :integer

    def self.boolean(definition, value)
      input = value.is_a?(String) || [true, false].include?(value) ? value.to_s.strip.downcase : ''
      invalid!(definition, 'must be true or false.') unless %w[true false].include?(input)

      input
    end
    private_class_method :boolean

    def self.enum(definition, value)
      input = value.is_a?(String) ? value.strip : ''
      input = input.downcase if definition[:case_insensitive]
      allowed = definition.fetch(:allowed)
      invalid!(definition, "must be #{allowed.join(' or ')}.") unless allowed.include?(input)

      input
    end
    private_class_method :enum

    def self.text(definition, value)
      input = value.is_a?(String) ? value.strip : ''
      invalid!(definition, 'must be nonblank text.') if input.empty?

      input
    end
    private_class_method :text

    def self.secret(definition, value)
      requirement = 'must be a valid, nonblank string without control characters.'
      invalid!(definition, requirement) unless value.is_a?(String) && value.valid_encoding?
      text = value.encoding.ascii_compatible? ? value : value.encode(Encoding::UTF_8)
      invalid!(definition, requirement) if text.match?(/\A[[:space:]]*\z/) || text.match?(/[[:cntrl:]]/)

      value
    rescue ArgumentError, EncodingError
      invalid!(definition, requirement)
    end
    private_class_method :secret

    def self.url(definition, value)
      scope = definition[:root_url] ? 'origin/root URL' : 'URL'
      requirement = "must be an HTTP(S) #{scope} with a host and a valid port, without userinfo, query, or fragment."
      input = value.is_a?(String) ? value.strip : ''
      uri = GluetunUrl.parse(input)
      invalid!(definition, requirement) if invalid_url_authority?(uri, input)
      invalid!(definition, requirement) if definition[:root_url] && !['', '/'].include?(uri.path)

      input
    rescue URI::InvalidURIError, GluetunUrl::InvalidBaseUrl
      invalid!(definition, requirement)
    end
    private_class_method :url

    def self.invalid_url_authority?(uri, input)
      # URI drops an empty userinfo/port delimiter, so also check the submitted authority.
      authority = input[%r{\Ahttps?://([^/?#]*)}i, 1]
      uri.userinfo || authority&.include?('@') || authority&.end_with?(':')
    end
    private_class_method :invalid_url_authority?
  end
end
