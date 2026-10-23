require_relative 'image_automation_context'

RSpec.describe ImagePublisher do # rubocop:disable Metrics/BlockLength
  include_context 'image automation'

  it 'publishes a validated release and leaves an existing SHA tag immutable' do
    seed(digest, tag: sha_tag, version: 'main')
    runner.publish
    expect(writes).to eq([release, 'v3.6', 'v3', 'latest'])
    expect(registry.fetch(sha_tag)).to eq(digest)
    expect(runner).to have_received(:smoke_container).with("#{image}@#{staged_digest}", 'amd64')
    expect(runner).to have_received(:smoke_container).with("#{image}@#{staged_digest}", 'arm64')
  end

  it 'creates an absent SHA tag once and makes a completed normal rerun a no-op' do
    runner.publish
    expect(registry.fetch(sha_tag)).to eq(staged_digest)
    writes.clear
    env['STAGED_DIGEST'] = seed(digest)
    runner.publish
    expect(writes).to be_empty
    expect(registry.values.uniq).to eq([staged_digest])
  end

  it 'preserves a security-refreshed exact release on a normal workflow rerun' do
    runner.tags_for(release).each { |tag| seed(digest, tag: tag, upstream: digest) }
    runner.publish
    expect(registry.values.uniq).to eq([digest])
    expect(writes).not_to include(release, 'latest')
  end

  it 'repairs an incomplete normal publication without replacing its exact release' do
    seed(digest, tag: release, upstream: digest)
    seed(staged_digest, tag: 'latest')
    runner.publish
    expect(registry.values.uniq).to eq([digest])
  end

  it 'rejects a historical release even if its newer successor has no registry tags yet' do
    published_releases << 'v3.7.0'
    expect { runner.publish }.to raise_error(described_class::Error, /Superseded/)
    expect(writes).to be_empty
  end

  it 'rejects an older release when newer images precede the GitHub Release' do
    seed(digest, tag: 'v3', version: 'v3.7.0')
    expect { runner.publish }.to raise_error(described_class::Error, /newer release image/)
    expect(writes).to be_empty
  end

  it 'rechecks release freshness after runtime validation' do
    allow(runner).to receive(:smoke_container) { published_releases << 'v3.7.0' }
    expect { runner.publish }.to raise_error(described_class::Error, /Superseded/)
    expect(writes).to be_empty
  end

  it 'stops between tag writes if a new release appears' do
    allow(runner).to receive(:summary).and_wrap_original do |original, message|
      original.call(message)
      published_releases << 'v3.7.0' if message.start_with?('Promoting')
    end
    expect { runner.publish }.to raise_error(described_class::Error, /Superseded/)
    expect(writes).to eq([sha_tag])
  end

  it 'rejects a moved Git tag or release source outside main' do
    allow(runner).to receive(:release_commit).and_return('f' * 40)
    expect { runner.publish }.to raise_error(described_class::Error, /tag moved/)
    allow(runner).to receive(:release_commit).and_return(commit)
    allow(runner).to receive(:api).with("compare/#{commit}...main")
                                  .and_return('merge_base_commit' => { 'sha' => 'f' * 40 })
    expect { runner.publish }.to raise_error(described_class::Error, /belong to main/)
    expect(writes).to be_empty
  end

  it 'rejects an existing exact release from different source' do
    seed(digest, tag: release, sha: 'f' * 40)
    expect { runner.publish }.to raise_error(described_class::Error, /different source/)
    expect(writes).to be_empty
  end

  it 'does not write production tags when metadata or runtime validation fails' do
    seed(staged_digest, version: 'wrong')
    expect { runner.publish }.to raise_error(described_class::Error, /labels disagree/)
    seed(staged_digest)
    allow(runner).to receive(:smoke_container).and_raise(described_class::Error, 'container failed')
    expect { runner.publish }.to raise_error(described_class::Error, /container failed/)
    expect(writes).to be_empty
  end

  it 'rejects a missing or ambiguous required architecture' do
    entries = indexes.fetch(staged_digest).fetch('manifests')
    entries.pop
    expect { runner.publish }.to raise_error(described_class::Error, /AMD64 and.*ARM64/)
    entries << entries.first
    expect { runner.publish }.to raise_error(described_class::Error, /AMD64 and.*ARM64/)
    expect(writes).to be_empty
  end

  it 'fails closed on API and registry errors' do
    allow(runner).to receive(:manifest).and_raise(described_class::Error, 'unauthorized')
    expect { runner.publish }.to raise_error(described_class::Error, /unauthorized/)
    allow(runner).to receive(:api).and_raise(described_class::Error, 'GitHub unavailable')
    expect { runner.publish }.to raise_error(described_class::Error, /GitHub unavailable/)
    expect(writes).to be_empty
  end

  it 'reports publication verification failures without rolling tags back' do
    allow(runner).to receive(:run).and_return('')
    expect { runner.publish }.to raise_error(described_class::Error, /verification failed/)
  end

  context 'security rebuilds' do # rubocop:disable Metrics/BlockLength
    before { security! }

    it 'updates only the four current release tags' do
      seed(digest, tag: 'main', version: 'main')
      seed(digest, tag: sha_tag, version: 'main')
      runner.publish
      expect(writes).to eq([release, 'v3.6', 'v3', 'latest'])
      expect(registry.fetch('main')).to eq(digest)
      expect(registry.fetch(sha_tag)).to eq(digest)
      expect(runner.incorporated?).to be(true)
    end

    it 'retries a partial failure with a newly built candidate rather than recovering old staging state' do
      allow(runner).to receive(:run).with('docker', 'buildx', 'imagetools', 'create', '--tag',
                                          "#{image}:v3.6", "#{image}@#{staged_digest}")
                                    .and_raise(described_class::Error, 'registry write failed')
      expect { runner.publish }.to raise_error(described_class::Error, /registry write failed/)
      expect(registry.fetch(release)).to eq(staged_digest)
      expect(runner.incorporated?).to be(false)
      env['STAGED_DIGEST'] = seed(digest, upstream: digest)
      runner.publish
      expect(registry.values.uniq).to eq([digest])
      expect(runner.incorporated?).to be(true)
    end

    it 'does not count a missing or divergent alias as an incorporated upstream digest' do
      runner.publish
      registry.delete('latest')
      expect(runner.incorporated?).to be(false)
      seed(digest, tag: 'latest', upstream: digest)
      expect(runner.incorporated?).to be(false)
    end

    it 'rejects a stale upstream snapshot even when forced' do
      env['FORCE'] = 'true'
      env['BASE_DIGEST'] = staged_digest
      expect { runner.publish }.to raise_error(described_class::Error, /upstream digest changed/)
      expect(writes).to be_empty
    end

    it 'rejects a superseded security rebuild' do
      published_releases << 'v3.7.0'
      expect { runner.publish }.to raise_error(described_class::Error, /Superseded/)
      expect(writes).to be_empty
    end
  end

  context 'branch publishing' do
    before do
      env['GITHUB_REF'] = 'refs/heads/main'
      seed(staged_digest, version: 'main')
    end

    it 'advances the branch while preserving existing SHA tags' do
      seed(digest, tag: 'main', version: 'main', sha: 'f' * 40)
      seed(digest, tag: sha_tag, version: 'main')
      runner.publish
      expect(writes).to eq(['main'])
      expect(registry.fetch('main')).to eq(staged_digest)
      expect(registry.fetch(sha_tag)).to eq(digest)
    end

    it 'rejects a branch build after the branch advances' do
      allow(runner).to receive(:api).with('git/ref/heads/main').and_return('object' => { 'sha' => 'f' * 40 })
      expect { runner.publish }.to raise_error(described_class::Error, /Stale branch/)
      expect(writes).to be_empty
    end

    %w[latest v3 v3.6 v3.6.0 sha/aaaaaaaaaaaa staging-1-1].each do |branch|
      it "rejects reserved branch tag #{branch}" do
        env['GITHUB_REF'] = "refs/heads/#{branch}"
        expect { runner.publish }.to raise_error(described_class::Error, /reserved image tag/)
        expect(writes).to be_empty
      end
    end
  end

  %w[pull_request pull_request_target repository_dispatch].each do |event|
    it "rejects unauthorized #{event} publishing" do
      env['GITHUB_EVENT_NAME'] = event
      expect { runner.publish }.to raise_error(described_class::Error, /authorized GitHub Actions/)
      expect(writes).to be_empty
    end
  end

  it 'rejects manual security runs outside the default branch and non-Actions execution' do
    security!
    env.merge!('GITHUB_EVENT_NAME' => 'workflow_dispatch', 'GITHUB_REF' => 'refs/heads/feature/test')
    expect { runner.publish }.to raise_error(described_class::Error, /authorized GitHub Actions/)
    env.merge!('GITHUB_REF' => 'refs/heads/main', 'GITHUB_ACTIONS' => 'false')
    expect { runner.publish }.to raise_error(described_class::Error, /authorized GitHub Actions/)
  end
end
