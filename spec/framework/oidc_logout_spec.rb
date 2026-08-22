require 'bundler/setup'
Bundler.require(:default)

require 'uri'
require_relative '../../framework/oidc_logout'

RSpec.describe Framework::OidcLogout do # rubocop:disable Metrics/BlockLength
  it 'adds the required Pocket ID logout parameters to a discovered endpoint' do
    result = described_class.url(
      endpoint: 'https://id.example.com/oidc/end-session?client_id=qbop',
      id_token: 'signed.id.token',
      post_logout_redirect_uri: 'https://qbop.example.com/logged-out'
    )
    params = URI.decode_www_form(URI(result).query).to_h

    expect(params).to eq(
      'client_id' => 'qbop', 'id_token_hint' => 'signed.id.token',
      'post_logout_redirect_uri' => 'https://qbop.example.com/logged-out'
    )
  end

  it 'replaces endpoint-provided redirect and token values' do
    result = described_class.url(
      endpoint: 'https://id.example.com/logout?id_token_hint=evil&post_logout_redirect_uri=https://evil.example',
      id_token: 'trusted-token', post_logout_redirect_uri: 'https://qbop.example.com/logged-out'
    )

    expect(URI.decode_www_form(URI(result).query).to_h).to include(
      'id_token_hint' => 'trusted-token',
      'post_logout_redirect_uri' => 'https://qbop.example.com/logged-out'
    )
  end

  it 'returns no URL when provider logout data is unavailable' do
    inputs = [
      { endpoint: '', id_token: 'token' },
      { endpoint: 'https://id.example.com/logout', id_token: '' }
    ]

    inputs.each do |input|
      expect(
        described_class.url(**input, post_logout_redirect_uri: 'https://qbop.example.com/logged-out')
      ).to be_nil
    end
  end
end
