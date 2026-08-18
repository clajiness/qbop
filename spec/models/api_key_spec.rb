require 'bundler/setup'
Bundler.require(:default)

require_relative '../support/database_helper'

SpecDatabase.reset!

RSpec.describe ApiKey do # rubocop:disable Metrics/BlockLength
  before { SpecDatabase.reset! }

  it 'issues a strong qbop token while persisting only its digest and display prefix' do
    created_at = Time.now
    issued_key = described_class.issue('  home assistant  ', now: created_at)
    api_key = issued_key.api_key
    token = issued_key.token

    expect(token).to match(/\Aqbop_[0-9a-f]{64}\z/)
    expect(described_class::TOKEN_BYTES).to be >= 32
    expect(api_key.name).to eq('home assistant')
    expect(api_key.token_prefix).to eq(token[0, 13])
    expect(api_key.token_digest).to eq(Digest::SHA256.hexdigest(token))
    expect(api_key.created_at).to be_within(0.001).of(created_at)
    expect(api_key.last_used_at).to be_nil
    expect(DB[:api_keys].first.values).not_to include(token)
  end

  it 'issues independent random tokens for multiple named keys' do
    first = described_class.issue('automation')
    second = described_class.issue('curl')

    expect(first.token).not_to eq(second.token)
    expect(described_class.count).to eq(2)
    expect(described_class.authenticate(first.token).id).to eq(first.api_key.id)
    expect(described_class.authenticate(second.token).id).to eq(second.api_key.id)
  end

  it 'requires a non-empty reasonably sized name' do
    expect { described_class.issue('   ') }.to raise_error(ArgumentError, 'name is required')
    expect { described_class.issue('x' * 101) }
      .to raise_error(ArgumentError, 'name cannot exceed 100 characters')
    expect(described_class.count).to eq(0)
  end

  it 'updates last use only when the complete token authenticates successfully' do
    issued_key = described_class.issue('testing')
    used_at = Time.now + 60

    expect(described_class.authenticate('qbop_invalid')).to be_nil
    expect(issued_key.api_key.refresh.last_used_at).to be_nil

    authenticated = described_class.authenticate(issued_key.token, now: used_at)

    expect(authenticated.id).to eq(issued_key.api_key.id)
    expect(issued_key.api_key.refresh.last_used_at).to be_within(0.001).of(used_at)
  end

  it 'stops authenticating a token immediately after its record is deleted' do
    issued_key = described_class.issue('temporary')
    issued_key.api_key.delete

    expect(described_class.authenticate(issued_key.token)).to be_nil
  end
end
