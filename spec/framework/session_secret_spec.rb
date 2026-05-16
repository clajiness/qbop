require 'bundler/setup'
Bundler.require(:default)

require_relative '../../framework/session_secret'

RSpec.describe Framework::SessionSecret do
  it 'loads an existing secret' do
    path = File.join(Dir.mktmpdir, 'session_secret.txt')
    File.write(path, "existing-secret\n")

    expect(described_class.load_or_create(path)).to eq('existing-secret')
  end

  it 'creates and persists a new secret' do
    path = File.join(Dir.mktmpdir, 'session_secret.txt')

    secret = described_class.load_or_create(path)

    expect(secret).to match(/\A[0-9a-f]{128}\z/)
    expect(File.read(path)).to eq(secret)
  end
end
