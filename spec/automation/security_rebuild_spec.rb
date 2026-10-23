require_relative 'image_automation_context'

RSpec.describe 'Upstream monitoring and build preparation' do # rubocop:disable Metrics/BlockLength
  include_context 'image automation'

  before do
    security!
    allow(runner).to receive(:release_file).with('Dockerfile', commit).and_return(dockerfile)
    allow(runner).to receive(:release_file).with('.ruby-version', commit).and_return("#{ruby_version}\n")
  end

  [[true, 'false', false], [false, 'false', true], [true, 'true', true],
   [false, 'true', true]].each do |same, force, build|
    it "requests rebuild=#{build} for incorporated=#{same}, force=#{force}" do
      env['FORCE'] = force
      runner.tags_for(release).each { |tag| seed(staged_digest, tag: tag, upstream: same ? digest : staged_digest) }
      expect(runner).to receive(:outputs).with(rebuild: build, release: release, commit: commit,
                                               base_image: base, base_digest: digest)
      runner.check
    end
  end

  it 'requests another build after an incomplete promotion even without an upstream change' do
    seed(staged_digest, tag: release, upstream: digest)
    expect(runner).to receive(:outputs).with(hash_including(rebuild: true))
    runner.check
  end

  it 'selects the highest numeric stable release across pages, excluding drafts and prereleases' do
    pages = [[{ 'tag_name' => 'v3.9.0', 'draft' => false, 'prerelease' => false },
              { 'tag_name' => 'v9.0.0', 'draft' => true, 'prerelease' => false }],
             [{ 'tag_name' => 'v3.10.0', 'draft' => false, 'prerelease' => false },
              { 'tag_name' => 'v4.0.0', 'draft' => false, 'prerelease' => true },
              { 'tag_name' => 'v4.0.0-rc1', 'draft' => false, 'prerelease' => false }]]
    allow(runner).to receive(:api).with('releases?per_page=100', '--paginate', '--slurp').and_return(pages)
    expect(runner.latest_tag).to eq('v3.10.0')
  end

  it 'resolves annotated tags to the actual release commit' do
    allow(runner).to receive(:api).with("git/ref/tags/#{release}")
                                  .and_return('object' => { 'sha' => 'f' * 40, 'type' => 'tag' })
    allow(runner).to receive(:api).with("git/tags/#{'f' * 40}")
                                  .and_return('object' => { 'sha' => commit, 'type' => 'commit' })
    expect(runner.release_commit(release)).to eq(commit)
  end

  it 'fails clearly when no stable release exists or the registry is unavailable' do
    published_releases.clear
    expect { runner.check }.to raise_error(ImagePublisher::Error, /Publish a stable/)
    published_releases << release
    allow(runner).to receive(:manifest).and_raise(ImagePublisher::Error, 'registry unavailable')
    expect { runner.check }.to raise_error(ImagePublisher::Error, /registry unavailable/)
  end

  it 'requires a compatible release Dockerfile instead of patching a legacy release' do
    expect(runner.security_base(dockerfile, ruby_version)).to eq(base)
    legacy = "FROM #{base}\nRUN apt update; apt install -y curl;\nRUN bundle install\n"
    expect do
      runner.security_base(legacy, ruby_version)
    end.to raise_error(ImagePublisher::Error, /compatible normal release/)
    expect do
      runner.security_base(dockerfile, '0.0.0')
    end.to raise_error(ImagePublisher::Error, /compatible normal release/)
  end

  it 'rejects unfrozen gems, automatic gem updates, and missing OS upgrades' do
    [dockerfile.sub('BUNDLE_FROZEN=true ', ''), dockerfile.sub('apt-get upgrade -y', 'apt-get install -y'),
     "#{dockerfile}\nRUN bundle \\\n  update\n"].each do |source|
      expect do
        runner.security_base(source, ruby_version)
      end.to raise_error(ImagePublisher::Error, /frozen security rebuilds/)
    end
  end

  describe 'preparation under the publishing lock' do # rubocop:disable Metrics/BlockLength
    around do |example|
      Dir.mktmpdir('qbop-prepare') do |directory|
        env['SOURCE_DIR'] = directory
        File.write(File.join(directory, 'Dockerfile'), dockerfile)
        File.write(File.join(directory, '.ruby-version'), "#{ruby_version}\n")
        File.write(File.join(directory, 'Gemfile'), 'released gems')
        File.write(File.join(directory, 'Gemfile.lock'), 'released lockfile')
        example.run
      end
    end

    it 'pins only the base build argument and leaves all source files untouched' do
      before = Dir.children(env.fetch('SOURCE_DIR')).to_h do |name|
        file = File.join(env.fetch('SOURCE_DIR'), name)
        [file, File.binread(file)]
      end
      expect(runner).to receive(:outputs).with(hash_including(base: "#{base}@#{digest}", proceed: true))
      runner.prepare
      before.each { |file, content| expect(File.binread(file)).to eq(content) }
    end

    it 'skips a queued rebuild when the digest was incorporated while it waited, unless forced' do
      runner.tags_for(release).each { |tag| seed(staged_digest, tag: tag, upstream: digest) }
      expect(runner).to receive(:outputs).with(hash_including(proceed: false))
      runner.prepare
      env['FORCE'] = 'true'
      expect(runner).to receive(:outputs).with(hash_including(proceed: true))
      runner.prepare
    end
  end
end
