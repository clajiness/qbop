require 'bundler/setup'
Bundler.require(:default)

require_relative '../../service/github'

RSpec.describe Service::Github do
  describe '#get_most_recent_tag' do
    it 'returns the most recent tag from GitHub' do
      github_service = Service::Github.new
      most_recent_tag = github_service.get_most_recent_tag

      expect(most_recent_tag).not_to be_nil
      expect(most_recent_tag).to match(/^v?\d+\.\d+\.\d+$/)
    end
  end
end
