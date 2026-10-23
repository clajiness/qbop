require_relative 'image_automation_context'

RSpec.describe 'Publisher command and runtime failures' do # rubocop:disable Metrics/BlockLength
  let(:runner) { ImagePublisher.new(env: { 'GITHUB_REPOSITORY' => 'clajiness/qbop' }, output: StringIO.new) }

  it 'uses argument arrays and reports ordinary subprocess exit failures' do
    expect(runner.run(RbConfig.ruby, '-e', 'puts ARGV.first', '$(untrusted); text')).to eq('$(untrusted); text')
    expect { runner.run(RbConfig.ruby, '-e', 'warn "operation failed"; exit 1') }
      .to raise_error(ImagePublisher::Error, /operation failed/)
  end

  it 'distinguishes missing tags from authentication and registry errors' do
    allow(runner).to receive(:run).and_raise(ImagePublisher::Error, 'example: not found')
    expect(runner.manifest('example', missing: true)).to be_nil
    allow(runner).to receive(:run).and_raise(ImagePublisher::Error, 'unauthorized')
    expect { runner.manifest('example', missing: true) }.to raise_error(ImagePublisher::Error, /unauthorized/)
  end

  it 'rejects dirty or mismatched source checkouts' do
    source_env = { 'SOURCE_SHA' => 'a' * 40 }
    verifier = ImagePublisher.new(env: source_env)
    allow(verifier).to receive(:run).and_return(' M Gemfile.lock')
    expect { verifier.verify_source! }.to raise_error(ImagePublisher::Error, /must be clean/)
    allow(verifier).to receive(:run).and_return('', 'f' * 40)
    expect { verifier.verify_source! }.to raise_error(ImagePublisher::Error, /match the requested commit/)
  end

  it 'removes a smoke-test container when its validation fails' do
    Dir.mktmpdir('qbop-smoke') do |directory|
      %w[.ruby-version Gemfile Gemfile.lock].each { |file| File.write(File.join(directory, file), '') }
      source_env = { 'SOURCE_DIR' => directory, 'GITHUB_REF' => 'refs/heads/main', 'SOURCE_SHA' => 'a' * 40 }
      verifier = ImagePublisher.new(env: source_env, output: StringIO.new)
      allow(verifier).to receive(:run).and_return('container')
      allow(verifier).to receive(:run).with('docker', 'exec', 'container', 'bundle', 'exec', 'ruby', '-e',
                                            ImagePublisher::RUNTIME_CHECK, '', 'x86_64-', 'main', 'a' * 40,
                                            anything, anything)
                                      .and_raise(ImagePublisher::Error, 'HTTP smoke test failed')
      expect(verifier).to receive(:run).with('docker', 'rm', '-fv', 'container')
      expect do
        verifier.smoke_container('local', 'amd64')
      end.to raise_error(ImagePublisher::Error, /HTTP smoke test failed/)
    end
  end

  it 'rejects arbitrary CLI method dispatch' do
    script = File.expand_path('../../.github/scripts/image_publisher.rb', __dir__)
    stdout, _stderr, status = Open3.capture3(RbConfig.ruby, script, 'instance_eval')
    expect(status).not_to be_success
    expect(stdout).to include('Expected check, prepare, or publish')
  end
end
