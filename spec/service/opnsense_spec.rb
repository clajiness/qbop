require 'bundler/setup'
Bundler.require(:default)

require_relative '../../service/opnsense'

RSpec.describe Service::Opnsense do
  let(:config) do
    {
      opnsense_interface_addr: 'https://opnsense.local',
      opnsense_api_key: 'test_api_key',
      opnsense_api_secret: 'test_api_secret',
      opnsense_alias_name: 'test_alias'
    }
  end
end
