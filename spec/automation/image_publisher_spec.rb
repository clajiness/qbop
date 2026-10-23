require_relative 'image_automation_context'

RSpec.describe ImagePublisher do # rubocop:disable Metrics/BlockLength
  include_context 'image automation'

  it 'publishes a validated release and leaves an existing SHA tag immutable' do
    seed(digest, tag: sha_tag, version: 'main')
    runner.publish
    expect(writes).to eq([release, 'v3.6', 'v3', 'latest', build_tag])
    expect(registry.fetch(build_tag)).to eq(staged_digest)
    expect(registry.fetch(sha_tag)).to eq(digest)
    expect(runner).to have_received(:smoke_container).with("#{image}@#{staged_digest}", 'amd64')
    expect(runner).to have_received(:smoke_container).with("#{image}@#{staged_digest}", 'arm64')
  end

  it 'publishes a release without creating SHA tags and makes a completed normal rerun a no-op' do
    runner.publish
    expect(writes).to eq([release, 'v3.6', 'v3', 'latest', build_tag])
    expect(registry.keys.grep(/\Asha-/)).to be_empty
    writes.clear
    env['STAGED_DIGEST'] = seed(digest)
    runner.publish
    expect(writes).to be_empty
    expect(registry.values.uniq).to eq([staged_digest])
    expect(registry.keys.grep(/\Asha-/)).to be_empty
  end

  it 'reuses the release on a new attempt without tagging its unused staging candidate or the reused image' do
    runner.publish
    original_build_tag = build_tag
    env['GITHUB_RUN_ATTEMPT'] = '2'
    env['STAGED_DIGEST'] = seed(digest)
    writes.clear
    runner.publish
    expect(writes).to be_empty
    expect(registry.fetch(original_build_tag)).to eq(staged_digest)
    expect(registry).not_to have_key(runner.build_tag)
    expect(registry.keys.grep(/\Abuild-/)).to eq([original_build_tag])
    expect(registry).not_to have_key(sha_tag)
    expect(registry.values).not_to include(digest)
    expect(runner).not_to have_received(:smoke_container).with("#{image}@#{digest}", anything)
  end

  it 'still tags a rerun candidate when its digest matches the selected release digest' do
    runner.publish
    original_build_tag = build_tag
    env['GITHUB_RUN_ATTEMPT'] = '2'
    writes.clear
    runner.publish
    expect(writes).to eq([runner.build_tag])
    expect(registry.fetch(original_build_tag)).to eq(staged_digest)
    expect(registry.fetch(runner.build_tag)).to eq(staged_digest)
  end

  it 'accepts an existing build tag with the selected digest without rewriting it' do
    seed(staged_digest, tag: build_tag)
    runner.publish
    expect(writes).to eq([release, 'v3.6', 'v3', 'latest'])
    expect(registry.fetch(build_tag)).to eq(staged_digest)
  end

  it 'rejects a conflicting build tag before changing any aliases' do
    seed(digest, tag: build_tag)
    expect { runner.publish }.to raise_error(described_class::Error, /Build tag.*refusing overwrite/)
    expect(writes).to be_empty
    expect(registry).to eq(build_tag => digest)
  end

  it 'rechecks build tag immutability after publishing the aliases' do
    allow(runner).to receive(:summary).and_wrap_original do |original, message|
      original.call(message)
      seed(digest, tag: build_tag) if message.start_with?("Promoting #{image}:latest ")
    end
    expect { runner.publish }.to raise_error(described_class::Error, /Build tag.*refusing overwrite/)
    expect(writes).to eq([release, 'v3.6', 'v3', 'latest'])
    expect(registry.fetch(build_tag)).to eq(digest)
  end

  it 'rejects missing, malformed, or oversized run metadata before writing tags' do
    %w[GITHUB_RUN_ID GITHUB_RUN_ATTEMPT].each do |key|
      [nil, '', '0', '-1', '01', '1/2', '1' * 128].each do |value|
        env[key] = value
        expect { runner.publish }.to raise_error(described_class::Error, /Invalid (run|build tag)/)
      end
      env[key] = '1'
    end
    expect(writes).to be_empty
  end

  it 'preserves a security-refreshed exact release on a normal workflow rerun' do
    runner.tags_for(release).each { |tag| seed(digest, tag: tag, upstream: digest) }
    runner.publish
    expect(registry.values.uniq).to eq([digest])
    expect(registry).not_to have_key(build_tag)
    expect(writes).not_to include(release, 'latest')
  end

  it 'repairs an incomplete normal publication without replacing its exact release' do
    seed(digest, tag: release, upstream: digest)
    seed(staged_digest, tag: 'latest')
    runner.publish
    expect(registry.values.uniq).to eq([digest])
    expect(registry).not_to have_key(build_tag)
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
    expect(writes).to eq([release])
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
    expect(registry).not_to have_key(build_tag)
  end

  it 'verifies the build tag after its registry write' do
    allow(runner).to receive(:run).with('docker', 'buildx', 'imagetools', 'create', '--tag',
                                        "#{image}:#{build_tag}", "#{image}@#{staged_digest}").and_return('')
    expect { runner.publish }.to raise_error(described_class::Error, /Build tag verification failed/)
    expect(registry.fetch('latest')).to eq(staged_digest)
  end

  context 'security rebuilds' do # rubocop:disable Metrics/BlockLength
    before { security! }

    it 'updates the four current release tags and adds a build tag, preserving SHA and branch tags' do
      seed(digest, tag: 'main', version: 'main')
      seed(digest, tag: sha_tag, version: 'main')
      runner.publish
      expect(writes).to eq([release, 'v3.6', 'v3', 'latest', build_tag])
      expect(registry.fetch(build_tag)).to eq(staged_digest)
      expect(registry.fetch('main')).to eq(digest)
      expect(registry.fetch(sha_tag)).to eq(digest)
      expect(runner.incorporated?).to be(true)
    end

    it 'gives successive forced rebuilds immutable build tags even when the upstream digest is unchanged' do
      env['FORCE'] = 'true'
      seed(digest, tag: sha_tag, version: 'main')
      runner.publish
      original_build_tag = build_tag
      env['GITHUB_RUN_ID'] = '40008926517'
      refreshed_digest = seed("sha256:#{'d' * 64}", upstream: digest)
      env['STAGED_DIGEST'] = refreshed_digest
      writes.clear
      runner.publish
      expect(writes).to eq([release, 'v3.6', 'v3', 'latest', runner.build_tag])
      expect(registry.fetch(original_build_tag)).to eq(staged_digest)
      expect(registry.fetch(runner.build_tag)).to eq(refreshed_digest)
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
      expect(registry).not_to have_key(build_tag)
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

  context 'branch publishing' do # rubocop:disable Metrics/BlockLength
    before do
      env['GITHUB_REF'] = 'refs/heads/main'
      seed(staged_digest, version: 'main')
    end

    it 'advances the branch while preserving existing SHA tags' do
      seed(digest, tag: 'main', version: 'main', sha: 'f' * 40)
      seed(digest, tag: sha_tag, version: 'main')
      runner.publish
      expect(writes).to eq(['main', build_tag])
      expect(registry.fetch('main')).to eq(staged_digest)
      expect(registry.fetch(sha_tag)).to eq(digest)
      expect(registry.fetch(build_tag)).to eq(staged_digest)
    end

    it 'is idempotent for one branch publication and gives a new attempt its own build tag' do
      runner.publish
      expect(registry.keys.grep(/\Asha-/)).to be_empty
      original_build_tag = runner.build_tag
      writes.clear
      runner.publish
      expect(writes).to be_empty
      env['GITHUB_RUN_ATTEMPT'] = '2'
      env['STAGED_DIGEST'] = seed(digest, version: 'main')
      runner.publish
      expect(writes).to eq(['main', runner.build_tag])
      expect(registry).to include('main' => digest,
                                  original_build_tag => staged_digest, runner.build_tag => digest)
      expect(registry.keys.grep(/\Asha-/)).to be_empty
    end

    it 'keeps distinct branch, release, and security builds from the same source addressable' do
      legacy_tag = 'sha-ffffffffffff'
      legacy_digest = seed("sha256:#{'e' * 64}", tag: legacy_tag, sha: 'f' * 40)
      runner.publish
      branch_build_tag = runner.build_tag
      env.merge!('GITHUB_REF' => "refs/tags/#{release}", 'GITHUB_RUN_ID' => '40008926517')
      env['STAGED_DIGEST'] = seed(digest)
      runner.publish
      release_build_tag = runner.build_tag
      env.merge!('PUBLISH_KIND' => 'security', 'GITHUB_REF' => 'refs/heads/main',
                 'GITHUB_EVENT_NAME' => 'schedule', 'GITHUB_RUN_ID' => '40008926518', 'FORCE' => 'true')
      refreshed_digest = seed("sha256:#{'d' * 64}", upstream: digest)
      env['STAGED_DIGEST'] = refreshed_digest
      runner.publish
      expect(registry).to include(legacy_tag => legacy_digest, 'main' => staged_digest,
                                  branch_build_tag => staged_digest, release_build_tag => digest,
                                  runner.build_tag => refreshed_digest, release => refreshed_digest)
      expect(registry).not_to have_key(sha_tag)
      expect(writes.grep(/\Asha-/)).to be_empty
    end

    it 'publishes a normalized branch using the same deterministic tag as its version labels' do
      env['GITHUB_REF'] = 'refs/heads/feature/foo'
      tag = "feature-foo-#{Digest::SHA256.hexdigest('feature/foo')[0, 12]}"
      seed(staged_digest, version: tag)
      runner.publish
      expect(writes).to eq([tag, build_tag])
      expect(registry.fetch(tag)).to eq(staged_digest)
    end

    it 'rejects a branch build after the branch advances' do
      allow(runner).to receive(:api).with('git/ref/heads/main').and_return('object' => { 'sha' => 'f' * 40 })
      expect { runner.publish }.to raise_error(described_class::Error, /Stale branch/)
      expect(writes).to be_empty
    end

    %w[latest v3 v3.6 v3.6.0 sha-aaaaaaaaaaaa sha/aaaaaaaaaaaa sha-feature
       build-aaaaaaaaaaaa-1-1 build/aaaaaaaaaaaa/1/1 build-feature staging-1-1 staging/1/1].each do |branch|
      it "rejects reserved branch tag #{branch}" do
        env['GITHUB_REF'] = "refs/heads/#{branch}"
        expect { runner.publish }.to raise_error(described_class::Error, /reserved image tag/)
        expect(writes).to be_empty
      end
    end
  end

  context 'branch tag mapping' do
    it 'preserves valid Docker tags, including main and the maximum length' do
      %w[main feature-foo Feature_foo release.candidate _private].push('a' * 128).each do |branch|
        expect(runner.branch_tag(branch)).to eq(branch)
      end
    end

    it 'distinguishes names that normalize alike using the original branch name' do
      names = %w[feature/foo feature-foo feature/-foo feature-/foo feature--foo]
      tags = names.map { |name| runner.branch_tag(name) }
      expect(tags.uniq.length).to eq(names.length)
      expect(tags.first).to eq("feature-foo-#{Digest::SHA256.hexdigest(names.first)[0, 12]}")
      expect(runner.branch_tag(names.first)).to eq(tags.first)
    end

    it 'produces valid bounded tags for Unicode, invalid initial characters, and long shared prefixes' do
      names = ['功能/测试', '-feature/test', '.feature/test', 'b' * 129, "#{'a' * 200}/one", "#{'a' * 200}/two"]
      tags = names.map do |name|
        tag = runner.branch_tag(name)
        expect(tag).to match(described_class::IMAGE_TAG)
        expect(tag.bytesize).to be <= 128
        expect(tag).to end_with("-#{Digest::SHA256.hexdigest(name)[0, 12]}")
        expect(tag).not_to match(described_class::RESERVED)
        tag
      end
      expect(tags.uniq.length).to eq(names.length)
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
