require_relative 'image_automation_context'

RSpec.describe 'Publishing workflow architecture' do # rubocop:disable Metrics/BlockLength
  let(:directory) { File.expand_path('../../.github/workflows', __dir__) }
  let(:docker) { YAML.safe_load_file(File.join(directory, 'docker.yml')) }
  let(:security) { YAML.safe_load_file(File.join(directory, 'security-rebuild.yml')) }
  let(:publisher) { YAML.safe_load_file(File.join(directory, 'publish-image.yml')) }

  it 'routes both triggers through one locked build-and-publish job' do
    [docker, security].each do |workflow|
      expect(workflow.dig('jobs', 'publish', 'uses')).to eq('./.github/workflows/publish-image.yml')
      steps = workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps', []) }
      expect(steps).not_to include(include('with' => include('push' => true)))
    end
    job = publisher.dig('jobs', 'publish')
    expect(job.fetch('concurrency')).to include('group' => 'qbop-release-publish', 'cancel-in-progress' => false)
    build = job.fetch('steps').find { |step| step['uses'].to_s.include?('build-push-action') }
    expect(build.dig('with', 'tags')).to match(/:staging-.*github.run_id.*github.run_attempt/)
    expect(build.dig('with', 'no-cache')).to eq('${{ inputs.security }}')
    expect(job.fetch('steps').last.fetch('run')).to end_with('image_publisher.rb publish')
  end

  it 'keeps PR builds outside registry credentials and write permissions' do
    job = docker.dig('jobs', 'pull_request')
    expect(docker.fetch('permissions')).to eq('contents' => 'read')
    expect(job.fetch('steps').map { |step| step['uses'] }.join).not_to include('login-action')
    build = job.fetch('steps').find { |step| step['uses'].to_s.include?('build-push-action') }
    expect(build.dig('with', 'push')).to be(false)
    expect(docker.dig('jobs', 'publish', 'if')).to eq("github.event_name != 'pull_request'")
  end

  it 'uses maintained automation and a separate exact application checkout with pinned actions' do
    steps = publisher.dig('jobs', 'publish', 'steps')
    expect(steps.first.dig('with', 'ref')).to eq('${{ github.event.repository.default_branch }}')
    checkouts = steps.select { |step| step['uses'].to_s.start_with?('actions/checkout@') }
    expect(checkouts.last.dig('with', 'ref')).to eq('${{ env.SOURCE_SHA }}')
    [docker, security, publisher].each do |workflow|
      workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps', []) }.each do |step|
        expect(step['uses']).to match(/@[0-9a-f]{40}\z/) if step['uses']
      end
    end
  end
end
