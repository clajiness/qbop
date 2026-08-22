module Framework
  # Enforces qbop's single-account OIDC identity-linking policy.
  class OidcIdentity
    class Unauthorized < StandardError; end

    TABLE = :account_oidc_identities
    MAX_SUBJECT_BYTES = 255

    def initialize(db:, issuer:)
      @db = db
      @issuer = issuer
    end

    def find(subject)
      identities.first(issuer: @issuer, subject: subject)
    end

    def authorize_new_link!(subject:, email:, email_verified:)
      raise Unauthorized unless valid_subject?(subject)
      raise Unauthorized unless identities.where(issuer: @issuer).empty?
      raise Unauthorized unless email_verified == true && email.is_a?(String) && !email.strip.empty?

      account = @db[:accounts].first(email: email)
      raise Unauthorized unless account

      account
    end

    private

    def valid_subject?(subject)
      subject.is_a?(String) && !subject.strip.empty? && subject.bytesize <= MAX_SUBJECT_BYTES
    end

    def identities
      @db[TABLE]
    end
  end
end
