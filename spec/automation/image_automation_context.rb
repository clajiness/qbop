require 'bundler/setup'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require_relative '../../.github/scripts/image_publisher'

RSpec.shared_context 'image automation' do
  subject(:runner) { ImagePublisher.new(env: env, output: StringIO.new) }

  let(:release) { 'v3.6.0' }
  let(:commit) { 'a' * 40 }
  let(:ruby_version) { File.read(File.expand_path('../../.ruby-version', __dir__)).strip }
  let(:base) { "ruby:#{ruby_version}-slim" }
  let(:digest) { "sha256:#{'b' * 64}" }
  let(:staged_digest) { "sha256:#{'c' * 64}" }
  let(:image) { 'ghcr.io/clajiness/qbop' }
  let(:sha_tag) { "sha-#{commit[0, 12]}" }
  let(:registry) { {} }
  let(:indexes) { {} }
  let(:configs) { {} }
  let(:writes) { [] }
  let(:published_releases) { [release] }
  let(:env) do
    { 'GITHUB_REPOSITORY' => 'clajiness/qbop', 'GITHUB_ACTIONS' => 'true', 'GITHUB_EVENT_NAME' => 'push',
      'GITHUB_REF' => "refs/tags/#{release}", 'GITHUB_SHA' => commit, 'SOURCE_SHA' => commit,
      'RELEASE_TAG' => release, 'PUBLISH_KIND' => 'normal', 'BASE_IMAGE' => base, 'BASE_DIGEST' => digest,
      'STAGED_DIGEST' => staged_digest, 'FORCE' => 'false' }
  end
  let(:dockerfile) { File.read(File.expand_path('../../Dockerfile', __dir__)) }

  def seed(id, tag: nil, version: release, sha: commit, upstream: nil)
    children = %w[amd64 arm64].map do |architecture|
      child = "sha256:#{Digest::SHA256.hexdigest("#{id}/#{architecture}")}"
      configs[child] = { 'org.opencontainers.image.version' => version, 'org.opencontainers.image.revision' => sha,
                         'org.opencontainers.image.base.name' => base,
                         'org.opencontainers.image.base.digest' => upstream }
      { 'digest' => child, 'platform' => { 'os' => 'linux', 'architecture' => architecture } }
    end
    indexes[id] = { 'digest' => id, 'manifests' => children }
    registry[tag] = id if tag
    id
  end

  def security!
    env.merge!('PUBLISH_KIND' => 'security', 'GITHUB_REF' => 'refs/heads/main', 'GITHUB_EVENT_NAME' => 'schedule')
    seed(staged_digest, upstream: digest)
  end

  before do # rubocop:disable Metrics/BlockLength
    allow(Open3).to receive(:capture3).and_raise('Unexpected external command in publishing policy test')
    seed(staged_digest)
    allow(runner).to receive(:verify_source!)
    allow(runner).to receive(:smoke_container)
    allow(runner).to receive(:api) do |path, *_options|
      case path
      when '' then { 'default_branch' => 'main' }
      when 'releases?per_page=100'
        [published_releases.map { |tag| { 'tag_name' => tag, 'draft' => false, 'prerelease' => false } }]
      when %r{\Agit/ref/tags/} then { 'object' => { 'sha' => commit, 'type' => 'commit' } }
      when %r{\Agit/ref/heads/} then { 'object' => { 'sha' => commit } }
      when %r{\Acompare/} then { 'merge_base_commit' => { 'sha' => commit } }
      else raise "Unexpected GitHub request: #{path}"
      end
    end
    allow(runner).to receive(:manifest) do |ref, missing: false|
      id = ref.start_with?("#{image}:") ? registry[ref.delete_prefix("#{image}:")] : ref.delete_prefix("#{image}@")
      value = ref == base ? indexes.fetch(staged_digest).merge('digest' => digest) : indexes[id]
      raise ImagePublisher::Error, 'manifest unknown' if !value && !missing

      value
    end
    allow(runner).to receive(:labels) { |id| configs.fetch(id) }
    allow(runner).to receive(:run) do |*arguments|
      raise "Unexpected command: #{arguments.inspect}" unless arguments.first(4) == %w[docker buildx imagetools create]

      tag = arguments.fetch(5).delete_prefix("#{image}:")
      writes << tag
      registry[tag] = arguments.fetch(6).delete_prefix("#{image}@")
      ''
    end
  end
end
