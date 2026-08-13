require 'bundler/setup'
Bundler.require(:default)

require_relative '../../framework/session_secret'

RSpec.describe Framework::SessionSecret do
  it 'loads an existing secret' do
    path = File.join(Dir.mktmpdir, 'session_secret.txt')
    secret = 's' * 64
    File.write(path, "#{secret}\n")

    expect(described_class.load_or_create(path)).to eq(secret)
  end

  it 'creates and persists a new secret' do
    path = File.join(Dir.mktmpdir, 'session_secret.txt')

    secret = described_class.load_or_create(path)

    expect(secret).to match(/\A[0-9a-f]{128}\z/)
    expect(File.read(path)).to eq(secret)
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it 'rejects an undersized existing secret' do
    path = File.join(Dir.mktmpdir, 'session_secret.txt')
    File.write(path, 'too-short')

    expect { described_class.load_or_create(path) }
      .to raise_error(ArgumentError, 'session secret must contain at least 64 bytes')
  end
end
