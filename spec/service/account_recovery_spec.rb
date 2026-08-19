require 'bundler/setup'
Bundler.require(:default)

require 'stringio'
require_relative '../support/database_helper'
SpecDatabase.reset!

require_relative '../../service/helpers'
require_relative '../../framework/authentication'
require_relative '../../service/account_recovery'

class AccountRecoveryInput
  attr_reader :prompts

  def initialize(*passwords)
    @passwords = passwords
    @prompts = []
  end

  def getpass(prompt)
    @prompts << prompt
    @passwords.shift&.dup
  end
end

RSpec.describe Service::AccountRecovery do # rubocop:disable Metrics/BlockLength
  def create_account
    Framework::Authentication.rodauth.create_account(
      login: 'admin@example.com', password: 'correct horse battery staple'
    )
  end

  def valid_password?(password)
    Framework::Authentication.rodauth.valid_login_and_password?(login: 'admin@example.com', password: password)
  end

  before do
    SpecDatabase.reset!
  end

  it 'resets the existing account password through Rodauth without exposing it' do
    create_account
    input = AccountRecoveryInput.new('emergency replacement password', 'emergency replacement password')
    output = StringIO.new

    described_class.new(input: input, output: output).reset_password

    password_hash = DB[:account_password_hashes].get(:password_hash)
    expect(input.prompts).to eq(['new password: ', 'confirm password: '])
    expect(output.string).to eq("password reset successfully\n")
    expect(output.string).not_to include('emergency replacement password')
    expect(DB[:accounts].count).to eq(1)
    expect(password_hash).to start_with('$2')
    expect(password_hash).not_to include('emergency replacement password')
    expect(valid_password?('correct horse battery staple')).to be(false)
    expect(valid_password?('emergency replacement password')).to be(true)
  end

  it 'rejects a mismatched confirmation without changing the password' do
    create_account
    input = AccountRecoveryInput.new('emergency replacement password', 'different confirmation')
    output = StringIO.new

    expect do
      described_class.new(input: input, output: output).reset_password
    end.to raise_error(described_class::Error, 'password confirmation does not match')

    expect(output.string).to be_empty
    expect(DB[:accounts].count).to eq(1)
    expect(valid_password?('correct horse battery staple')).to be(true)
    expect(valid_password?('emergency replacement password')).to be(false)
  end

  it 'uses Rodauth password requirements' do
    create_account
    input = AccountRecoveryInput.new('short', 'short')

    expect do
      described_class.new(input: input, output: StringIO.new).reset_password
    end.to raise_error(described_class::Error, /invalid password/)

    expect(valid_password?('correct horse battery staple')).to be(true)
  end

  it 'fails clearly without prompting or creating an account when none exists' do
    input = AccountRecoveryInput.new('emergency replacement password', 'emergency replacement password')

    expect do
      described_class.new(input: input, output: StringIO.new).reset_password
    end.to raise_error(described_class::Error, 'no administrator account exists')

    expect(input.prompts).to be_empty
    expect(DB[:accounts].count).to eq(0)
    expect(DB[:account_password_hashes].count).to eq(0)
  end

  it 'is wired to the shipped Rake command' do
    create_account
    load File.expand_path('../../Rakefile', __dir__)
    task = Rake::Task['user:reset-password']
    task.reenable
    allow($stdin).to receive(:getpass).and_return(
      'command replacement password'.dup,
      'command replacement password'.dup
    )

    expect { task.invoke }.to output("password reset successfully\n").to_stdout
    expect(valid_password?('correct horse battery staple')).to be(false)
    expect(valid_password?('command replacement password')).to be(true)
  end
end
