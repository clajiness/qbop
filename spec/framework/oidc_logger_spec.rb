require 'logger'
require 'stringio'
require_relative '../../framework/oidc_logger'

RSpec.describe Framework::OidcLogger do
  it 'retains failure context without logging provider-controlled exception details' do
    output = StringIO.new
    logger = described_class.new(Logger.new(output))

    logger.error(
      '(openid_connect) Authentication failure! invalid:key: Example::CallbackError, unsafe token-like provider detail'
    )

    expect(output.string).to include('Authentication failure!', 'Example::CallbackError')
    expect(output.string).not_to include('invalid:key', 'unsafe token-like provider detail')
  end

  it 'passes ordinary diagnostic messages through unchanged' do
    output = StringIO.new
    logger = described_class.new(Logger.new(output))

    logger.debug('(openid_connect) Request phase initiated.')

    expect(output.string).to include('Request phase initiated.')
  end

  it 'sanitizes lazily generated failure messages too' do
    output = StringIO.new
    logger = described_class.new(Logger.new(output))

    logger.error do
      '(openid_connect) Authentication failure! invalid: Example::CallbackError, provider secret'
    end

    expect(output.string).to include('Authentication failure!', 'Example::CallbackError')
    expect(output.string).not_to include('provider secret', 'invalid:')
  end
end
