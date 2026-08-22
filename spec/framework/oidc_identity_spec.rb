require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'
SpecDatabase.reset!
require_relative '../../framework/oidc_identity'

RSpec.describe Framework::OidcIdentity do # rubocop:disable Metrics/BlockLength
  subject(:identity) { described_class.new(db: DB, issuer: issuer) }

  let(:issuer) { 'https://id.example.com' }

  before do
    SpecDatabase.reset!
    @account_id = DB[:accounts].insert(email: 'admin@example.com')
  end

  it 'authorizes a first link only for the verified email of the existing account' do
    account = identity.authorize_new_link!(
      subject: 'subject-1', email: 'admin@example.com', email_verified: true
    )

    expect(account[:id]).to eq(@account_id)
  end

  it 'rejects malformed subjects, missing email, unverified email, and a different email' do
    invalid_claims = [
      { subject: '', email: 'admin@example.com', email_verified: true },
      { subject: ' ', email: 'admin@example.com', email_verified: true },
      { subject: 123, email: 'admin@example.com', email_verified: true },
      { subject: 'subject-1', email: '', email_verified: true },
      { subject: 'subject-1', email: ['admin@example.com'], email_verified: true },
      { subject: 'subject-1', email: 'admin@example.com', email_verified: false },
      { subject: 'subject-1', email: 'other@example.com', email_verified: true }
    ]

    invalid_claims.each do |claims|
      expect { identity.authorize_new_link!(**claims) }.to raise_error(described_class::Unauthorized)
    end
  end

  it 'accepts only the literal boolean true for initial email verification' do
    [false, 'true', 'false', 1, 0, nil].each do |value|
      expect do
        identity.authorize_new_link!(
          subject: 'subject-1', email: 'admin@example.com', email_verified: value
        )
      end.to raise_error(described_class::Unauthorized)
    end
  end

  it 'uses the database email collation without adding another normalization policy' do
    expect do
      identity.authorize_new_link!(
        subject: 'subject-1', email: 'ADMIN@example.com', email_verified: true
      )
    end.not_to raise_error

    expect do
      identity.authorize_new_link!(
        subject: 'subject-1', email: ' admin@example.com ', email_verified: true
      )
    end.to raise_error(described_class::Unauthorized)
  end

  it 'will not authorize a replacement subject for an issuer that is already linked' do
    DB[:account_oidc_identities].insert(
      account_id: @account_id, issuer: issuer, subject: 'subject-1'
    )

    expect do
      identity.authorize_new_link!(
        subject: 'subject-2', email: 'admin@example.com', email_verified: true
      )
    end.to raise_error(described_class::Unauthorized)
  end

  it 'looks up identities using issuer and subject together' do
    DB[:account_oidc_identities].insert(
      account_id: @account_id, issuer: issuer, subject: 'shared-subject'
    )
    other = described_class.new(db: DB, issuer: 'https://other-id.example.com')

    expect(identity.find('shared-subject')).to include(account_id: @account_id)
    expect(other.find('shared-subject')).to be_nil
  end

  it 'keeps the same subject from different issuers as distinct identities' do
    DB[:account_oidc_identities].insert(
      account_id: @account_id, issuer: issuer, subject: 'shared-subject'
    )
    DB[:account_oidc_identities].insert(
      account_id: @account_id, issuer: 'https://other-id.example.com', subject: 'shared-subject'
    )

    expect(DB[:account_oidc_identities].where(subject: 'shared-subject').count).to eq(2)
  end
end
