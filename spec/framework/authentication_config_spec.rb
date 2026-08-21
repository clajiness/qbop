require 'bundler/setup'
Bundler.require(:default)

require_relative '../../framework/authentication_config'

RSpec.describe Framework::AuthenticationConfig do # rubocop:disable Metrics/BlockLength
  def config(overrides = {})
    described_class.new(overrides.transform_keys(&:to_s))
  end

  it 'preserves qbop 3.0 authentication defaults' do
    value = config.validate!

    expect(value.web_auth_enabled?).to be(true)
    expect(value.oidc_enabled?).to be(false)
    expect(value.oidc_active?).to be(false)
    expect(value.oidc_auto_redirect?).to be(false)
    expect(value.oidc_auto_redirect_active?).to be(false)
    expect(value.local_login_enabled?).to be(true)
  end

  it 'gives enabled local recovery precedence over automatic OIDC redirect' do
    recovery = config(OIDC_AUTO_REDIRECT: 'true', LOCAL_LOGIN_ENABLED: 'true')
    oidc_only = config(OIDC_AUTO_REDIRECT: 'true', LOCAL_LOGIN_ENABLED: 'false')

    expect(recovery.oidc_auto_redirect?).to be(true)
    expect(recovery.oidc_auto_redirect_active?).to be(false)
    expect(oidc_only.oidc_auto_redirect_active?).to be(true)
  end

  it 'uses qbop boolean parsing consistently and treats only case-insensitive true as enabled' do
    values = {
      'true' => true, 'TRUE' => true, 'false' => false, 'FALSE' => false,
      '1' => false, '0' => false, 'yes' => false, 'no' => false,
      'on' => false, 'off' => false, 'garbage' => false, '' => false, ' ' => false
    }

    values.each do |input, expected|
      value = config(WEB_AUTH_ENABLED: 'false', OIDC_ENABLED: input)
      expect(value.oidc_enabled?).to eq(expected), "expected #{input.inspect} to parse as #{expected}"
    end
  end

  it 'ignores incomplete OIDC settings while web authentication is disabled' do
    value = config(WEB_AUTH_ENABLED: 'false', OIDC_ENABLED: 'true').validate!

    expect(value.oidc_enabled?).to be(true)
    expect(value.oidc_active?).to be(false)
  end

  it 'builds fixed callback URLs from a validated public origin' do
    value = config(
      OIDC_ENABLED: 'true', OIDC_ISSUER: 'https://id.example.com/realms/qbop',
      OIDC_CLIENT_ID: 'qbop', OIDC_CLIENT_SECRET: 'secret',
      OIDC_PUBLIC_URL: 'https://qbop.example.com/'
    ).validate!

    expect(value.oidc_callback_url).to eq('https://qbop.example.com/auth/openid_connect/callback')
    expect(value.oidc_logout_callback_url).to eq('https://qbop.example.com/logged-out')
    expect(value.force_secure_cookie?).to be(true)
  end

  it 'allows HTTP only for loopback development origins' do
    value = config(
      OIDC_ENABLED: 'true', OIDC_ISSUER: 'https://id.example.com',
      OIDC_CLIENT_ID: 'qbop', OIDC_CLIENT_SECRET: 'secret',
      OIDC_PUBLIC_URL: 'http://localhost:4567'
    ).validate!

    expect(value.force_secure_cookie?).to be(false)
  end

  it 'requires HTTPS for the issuer because discovery and back-channel credentials require TLS' do
    expect do
      config(
        OIDC_ENABLED: 'true', OIDC_ISSUER: 'http://127.0.0.1:8080',
        OIDC_CLIENT_ID: 'qbop', OIDC_CLIENT_SECRET: 'secret',
        OIDC_PUBLIC_URL: 'http://localhost:4567'
      ).validate!
    end.to raise_error(described_class::Error, /OIDC_ISSUER/)
  end

  it 'does not mistake a hostname beginning with 127 for loopback' do
    expect do
      config(
        OIDC_ENABLED: 'true', OIDC_ISSUER: 'https://id.example.com',
        OIDC_CLIENT_ID: 'qbop', OIDC_CLIENT_SECRET: 'secret',
        OIDC_PUBLIC_URL: 'http://127.attacker.example'
      ).validate!
    end.to raise_error(described_class::Error, /OIDC_PUBLIC_URL/)
  end

  it 'requires every active OIDC setting' do
    base = {
      OIDC_ENABLED: 'true', OIDC_ISSUER: 'https://id.example.com',
      OIDC_CLIENT_ID: 'qbop', OIDC_CLIENT_SECRET: 'secret',
      OIDC_PUBLIC_URL: 'https://qbop.example.com'
    }

    %i[OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_PUBLIC_URL].each do |key|
      expect { config(base.merge(key => nil)).validate! }
        .to raise_error(described_class::Error, /#{key} must be set/)
    end
  end

  it 'rejects insecure, credentialed, or request-derived public URLs' do
    base = {
      OIDC_ENABLED: 'true', OIDC_ISSUER: 'https://id.example.com',
      OIDC_CLIENT_ID: 'qbop', OIDC_CLIENT_SECRET: 'secret'
    }

    ['http://qbop.example.com', 'http://localhost.evil.test',
     'https://qbop.example.com@evil.test', 'https://user@qbop.example.com',
     'https://qbop.example.com/path', 'https://qbop.example.com?next=evil',
     'https://evil.test/?https://qbop.example.com', '//evil.test',
     'javascript:alert(1)', 'data:text/html,unsafe'].each do |url|
      expect { config(base.merge(OIDC_PUBLIC_URL: url)).validate! }
        .to raise_error(described_class::Error, /OIDC_PUBLIC_URL/)
    end
  end

  it 'uses the exact explicitly configured origin instead of hostname prefix matching' do
    value = config(
      OIDC_ENABLED: 'true', OIDC_ISSUER: 'https://id.example.com',
      OIDC_CLIENT_ID: 'qbop', OIDC_CLIENT_SECRET: 'secret',
      OIDC_PUBLIC_URL: 'https://qbop.example.com.evil.test'
    ).validate!

    expect(value.oidc_callback_url).to eq(
      'https://qbop.example.com.evil.test/auth/openid_connect/callback'
    )
  end

  it 'rejects impossible login-mode combinations' do
    expect { config(LOCAL_LOGIN_ENABLED: 'false').validate! }
      .to raise_error(described_class::Error, /LOCAL_LOGIN_ENABLED=false requires OIDC_ENABLED=true/)
    expect { config(OIDC_AUTO_REDIRECT: 'true').validate! }
      .to raise_error(described_class::Error, /OIDC_AUTO_REDIRECT requires OIDC_ENABLED=true/)
  end
end
