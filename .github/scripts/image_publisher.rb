require 'base64'
require 'digest'
require 'json'
require 'open3'
require 'time'
require 'uri'

# One publisher, run inside publish-image.yml's shared Actions concurrency group.
class ImagePublisher # rubocop:disable Metrics/ClassLength
  TAG = /\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z/
  SHA = /\A[0-9a-f]{40}\z/
  DIGEST = /\Asha256:[0-9a-f]{64}\z/
  BASE = /\Aruby:([0-9]+\.[0-9]+\.[0-9]+)-slim(?:-[a-z]+)?\z/
  IMAGE_TAG = /\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z/
  RESERVED = /\A(?:latest|v[0-9]+(?:\.[0-9]+){0,2}|(?:sha|build|staging)-.*)\z/
  RUNTIME_CHECK = <<~'CHECK'.freeze
    require 'digest'
    abort 'Ruby changed' unless RUBY_VERSION == ARGV.shift
    abort 'Architecture changed' unless RUBY_PLATFORM.start_with?(ARGV.shift)
    %w[VERSION COMMIT_SHA].each { |key| abort "#{key} changed" unless ENV[key] == ARGV.shift }
    %w[Gemfile Gemfile.lock].each do |file|
      abort "#{file} changed" unless Digest::SHA256.file(file).hexdigest == ARGV.shift
    end
    require 'net/http'
    30.times do
      begin
        response = Net::HTTP.start('127.0.0.1', 4567, open_timeout: 2, read_timeout: 2) { |http| http.get('/about') }
        exit 0 if response.code == '200' && response.body.include?(ENV.fetch('VERSION'))
      rescue SystemCallError, Timeout::Error, EOFError
        # Puma may still be starting.
      end
      sleep 2
    end
    abort 'Application HTTP smoke test failed'
  CHECK

  class Error < StandardError; end

  def initialize(env: ENV, output: $stdout)
    @env = env
    @output = output
  end

  def run(*arguments)
    stdout, stderr, status = Open3.capture3(*arguments)
    raise Error, "#{arguments.join(' ')} failed: #{stderr.strip}" unless status.success?

    stdout.strip
  end

  def validate(pattern, value, name)
    raise Error, "Invalid #{name}: #{value.inspect}" unless value.is_a?(String) && pattern.match?(value)

    value
  end

  def api(path, *options)
    JSON.parse(run('gh', 'api', "repos/#{repository}/#{path}".delete_suffix('/'), *options))
  end

  def repository
    validate(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}, @env.fetch('GITHUB_REPOSITORY'), 'repository')
  end

  def image
    "ghcr.io/#{repository.downcase}"
  end

  def semantic_version(tag)
    TAG.match(validate(TAG, tag, 'stable release')).captures.map(&:to_i)
  end

  def latest_tag
    tags = api('releases?per_page=100', '--paginate', '--slurp').flatten.filter_map do |release|
      tag = release.fetch('tag_name')
      tag if !release.fetch('draft') && !release.fetch('prerelease') && TAG.match?(tag.to_s)
    end
    tags.max_by { |tag| semantic_version(tag) }
  end

  def release_commit(tag)
    object = api("git/ref/tags/#{validate(TAG, tag, 'release tag')}").fetch('object')
    10.times do
      sha = validate(SHA, object.fetch('sha'), 'release object')
      return sha if object.fetch('type') == 'commit'
      break unless object.fetch('type') == 'tag'

      object = api("git/tags/#{sha}").fetch('object')
    end
    raise Error, "#{tag} does not resolve to a commit."
  end

  def release_file(path, sha)
    Base64.decode64(api("contents/#{path}?ref=#{sha}").fetch('content'))
  end

  def security_base(dockerfile, ruby)
    base = dockerfile[/^ARG BASE_IMAGE=(\S+)$/, 1]
    supported = dockerfile.include?('FROM ${BASE_IMAGE}') && dockerfile.include?('BUNDLE_FROZEN=true bundle install') &&
                dockerfile.include?('apt-get upgrade -y') && !/bundle\s+update/.match?(dockerfile.gsub(/\\\s*\n/, ' '))
    unless supported && BASE.match?(base.to_s) && BASE.match(base)[1] == ruby.strip
      raise Error, 'Release Dockerfile does not support frozen security rebuilds; publish a compatible normal release.'
    end

    base
  end

  def manifest(ref, missing: false)
    JSON.parse(run('docker', 'buildx', 'imagetools', 'inspect', ref, '--format', '{{json .Manifest}}'))
  rescue Error => e
    return nil if missing && /: not found\s*\z|manifest unknown/i.match?(e.message)

    raise
  end

  def platforms(value)
    entries = value.fetch('manifests').select do |entry|
      platform = entry.fetch('platform')
      platform['os'] == 'linux' && %w[amd64 arm64].include?(platform['architecture']) &&
        [nil, platform['architecture'] == 'arm64' ? 'v8' : nil].include?(platform['variant'])
    end
    unless entries.map { |entry| entry.dig('platform', 'architecture') }.sort == %w[amd64 arm64]
      raise Error, 'Image must contain exactly one AMD64 and one ARM64 platform manifest.'
    end

    entries
  end

  def labels(digest)
    JSON.parse(run('docker', 'buildx', 'imagetools', 'inspect', "#{image}@#{digest}",
                   '--format', '{{json .Image}}')).fetch('config').fetch('Labels', {})
  end

  def metadata(digest)
    labels(platforms(manifest("#{image}@#{digest}")).first.fetch('digest'))
  end

  def tags_for(tag)
    major, minor = semantic_version(tag)
    [tag, "v#{major}.#{minor}", "v#{major}", 'latest']
  end

  def published(tags)
    tags.to_h { |tag| [tag, manifest("#{image}:#{tag}", missing: true)&.fetch('digest')] }
  end

  def expected_labels
    expected = { 'org.opencontainers.image.version' => version, 'org.opencontainers.image.revision' => commit }
    return expected unless security?

    expected.merge('org.opencontainers.image.base.name' => @env.fetch('BASE_IMAGE'),
                   'org.opencontainers.image.base.digest' => @env.fetch('BASE_DIGEST'))
  end

  # All four tags must agree; an interrupted publication must remain retryable.
  def incorporated?
    digests = published(tags_for(version)).values
    return false if digests.any?(nil) || digests.uniq.length != 1

    actual = metadata(digests.first)
    expected_labels.all? { |key, value| actual[key] == value }
  end

  def check # rubocop:disable Metrics/AbcSize
    @env['PUBLISH_KIND'] = 'security'
    @env['RELEASE_TAG'] = latest_tag || raise(Error, 'Publish a stable vX.Y.Z GitHub Release before rebuilding.')
    @env['SOURCE_SHA'] = release_commit(version)
    @env['BASE_IMAGE'] = security_base(release_file('Dockerfile', commit), release_file('.ruby-version', commit))
    @env['BASE_DIGEST'] = manifest(@env.fetch('BASE_IMAGE')).tap { |value| platforms(value) }.fetch('digest')
    needed = @env['FORCE'] == 'true' || !incorporated?
    summary("#{version} (#{commit}): #{@env.fetch('BASE_IMAGE')}@#{@env.fetch('BASE_DIGEST')}; rebuild=#{needed}")
    outputs(rebuild: needed, release: version, commit: commit,
            base_image: @env.fetch('BASE_IMAGE'), base_digest: @env.fetch('BASE_DIGEST'))
  end

  def security?
    @env['PUBLISH_KIND'] == 'security'
  end

  def branch?
    !security? && @env.fetch('GITHUB_REF').start_with?('refs/heads/')
  end

  def commit
    validate(SHA, @env.fetch('SOURCE_SHA'), 'source commit')
  end

  def version
    return validate(TAG, @env.fetch('RELEASE_TAG'), 'release tag') if security?

    ref = @env.fetch('GITHUB_REF')
    return validate(TAG, ref.delete_prefix('refs/tags/'), 'release tag') unless branch?

    branch_tag(ref.delete_prefix('refs/heads/'))
  end

  def branch_tag(name)
    tag = name.gsub(/[^A-Za-z0-9_.-]+/, '-')
    raise Error, 'Branch name collides with a reserved image tag.' if RESERVED.match?(tag)

    return tag if tag == name && IMAGE_TAG.match?(tag)

    tag = "branch-#{tag}" unless /\A[A-Za-z0-9_]/.match?(tag)
    "#{tag[0, 115]}-#{Digest::SHA256.hexdigest(name)[0, 12]}"
  end

  def build_tag
    run_id = validate(/\A[1-9][0-9]*\z/, @env['GITHUB_RUN_ID'], 'run ID')
    attempt = validate(/\A[1-9][0-9]*\z/, @env['GITHUB_RUN_ATTEMPT'], 'run attempt')
    validate(IMAGE_TAG, "build-#{commit[0, 12]}-#{run_id}-#{attempt}", 'build tag')
  end

  def check_build_tag!(tag, digest)
    existing = published([tag])[tag]
    if existing && existing != digest
      raise Error, "Build tag #{tag} already points to a different digest; refusing overwrite."
    end

    existing
  end

  def promote(tag, digest)
    fresh!
    summary("Promoting #{image}:#{tag} to #{digest}")
    run('docker', 'buildx', 'imagetools', 'create', '--tag', "#{image}:#{tag}", "#{image}@#{digest}")
  end

  def authorize! # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    raise Error, 'Invalid publication kind.' unless %w[normal security].include?(@env['PUBLISH_KIND'])

    event = @env.fetch('GITHUB_EVENT_NAME')
    ref = @env.fetch('GITHUB_REF')
    default_ref = "refs/heads/#{api('').fetch('default_branch')}"
    allowed = if security?
                %w[schedule workflow_dispatch].include?(event) && ref == default_ref
              else
                event == 'push' || (event == 'workflow_dispatch' && ref == default_ref && branch?)
              end
    unless @env['GITHUB_ACTIONS'] == 'true' && allowed
      raise Error, 'Publishing requires an authorized GitHub Actions push or default-branch maintenance run.'
    end
    raise Error, 'Source differs from triggering commit.' if !security? && commit != @env.fetch('GITHUB_SHA')

    version
  end

  def verify_source!
    directory = @env.fetch('SOURCE_DIR', 'source')
    clean = run('git', '-C', directory, 'status', '--porcelain', '--untracked-files=all').empty?
    return if clean && run('git', '-C', directory, 'rev-parse', 'HEAD') == commit

    raise Error, 'Application checkout must be clean and match the requested commit.'
  end

  def fresh! # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    if branch?
      branch = URI.encode_www_form_component(@env.fetch('GITHUB_REF').delete_prefix('refs/heads/'))
      raise Error, 'Stale branch build.' unless api("git/ref/heads/#{branch}").dig('object', 'sha') == commit

      return
    end
    raise Error, 'Release tag moved.' unless release_commit(version) == commit

    unless api("compare/#{commit}...main").dig('merge_base_commit', 'sha') == commit
      raise Error, 'Release commit must belong to main.'
    end

    latest = latest_tag
    if latest && (semantic_version(latest) <=> semantic_version(version)) == 1
      raise Error, 'Superseded release; refusing publication.'
    end
    if security? && (latest != version ||
                     manifest(@env.fetch('BASE_IMAGE')).fetch('digest') != @env.fetch('BASE_DIGEST'))
      raise Error, 'Security release or upstream digest changed; run the workflow again.'
    end

    published(tags_for(version)).values.compact.uniq.each do |digest|
      tag = metadata(digest).fetch('org.opencontainers.image.version').delete_prefix('v')
      if (semantic_version("v#{tag}") <=> semantic_version(version)) == 1
        raise Error, 'A newer release image is already published.'
      end
    end
  end

  def prepare # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    authorize!
    verify_source!
    fresh!
    dockerfile = File.read(File.join(@env.fetch('SOURCE_DIR', 'source'), 'Dockerfile'))
    base = dockerfile[/^ARG BASE_IMAGE=(\S+)$/, 1].to_s
    if security?
      ruby = File.read(File.join(@env.fetch('SOURCE_DIR', 'source'), '.ruby-version'))
      unless security_base(dockerfile, ruby) == @env.fetch('BASE_IMAGE')
        raise Error, 'Monitored base differs from release.'
      end

      base = "#{@env.fetch('BASE_IMAGE')}@#{validate(DIGEST, @env.fetch('BASE_DIGEST'), 'base digest')}"
    end
    proceed = !security? || @env['FORCE'] == 'true' || !incorporated?
    outputs(image: image, version: version, base: base, date: Time.now.utc.iso8601, proceed: proceed)
  end

  def validate_image!(digest)
    ref = "#{image}@#{validate(DIGEST, digest, 'candidate digest')}"
    platforms(manifest(ref)).each do |entry|
      actual = labels(entry.fetch('digest'))
      unless expected_labels.all? { |key, value| actual[key] == value }
        raise Error, 'Candidate source/base labels disagree with publication request.'
      end

      smoke_container(ref, entry.dig('platform', 'architecture'))
    end
    summary("Validated AMD64 and ARM64: #{ref}")
  end

  def smoke_container(ref, architecture) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    platform = "linux/#{architecture}"
    run('docker', 'pull', '--platform', platform, ref)
    container = run('docker', 'run', '-d', '--platform', platform, '--network', 'none',
                    '-e', 'WEB_AUTH_ENABLED=false', '-e', 'OPN_SKIP=true', '-e', 'QBIT_SKIP=true', ref)
    directory = @env.fetch('SOURCE_DIR', 'source')
    ruby = File.read(File.join(directory, '.ruby-version')).strip
    hashes = %w[Gemfile Gemfile.lock].map { |file| Digest::SHA256.file(File.join(directory, file)).hexdigest }
    cpu = architecture == 'amd64' ? 'x86_64-' : 'aarch64-'
    run('docker', 'exec', container, 'bundle', 'exec', 'ruby', '-e', RUNTIME_CHECK, ruby, cpu, version, commit, *hashes)
  ensure
    if container
      begin
        @output.puts(run('docker', 'logs', container))
      ensure
        run('docker', 'rm', '-fv', container)
      end
    end
  end

  def publish # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    authorize!
    verify_source!
    fresh!
    tags = branch? ? [version] : tags_for(version)
    existing = published(tags)
    exact = existing[version]
    if !branch? && exact && metadata(exact)['org.opencontainers.image.revision'] != commit
      raise Error, 'Existing exact release has a different source; publish a new application version.'
    end

    # Normal reruns keep the exact release image, including any security refresh.
    digest = !branch? && !security? && exact ? exact : @env.fetch('STAGED_DIGEST')
    permanent_tag = build_tag if digest == @env.fetch('STAGED_DIGEST')
    check_build_tag!(permanent_tag, digest) if permanent_tag
    validate_image!(digest)
    tags.each do |tag|
      next if published([tag])[tag] == digest

      promote(tag, digest)
    end
    unless published(tags).values.all?(digest)
      raise Error, "Publication verification failed for #{digest}; inspect tags and rerun."
    end

    if permanent_tag
      promote(permanent_tag, digest) unless check_build_tag!(permanent_tag, digest)
      unless published([permanent_tag])[permanent_tag] == digest
        raise Error, "Build tag verification failed for #{permanent_tag}; inspect tags and rerun."
      end

      tags << permanent_tag
    end

    summary("Published #{tags.join(', ')} at #{digest}")
  end

  def outputs(**values)
    File.open(@env.fetch('GITHUB_OUTPUT'), 'a') { |file| values.each { |key, value| file.puts("#{key}=#{value}") } }
  end

  def summary(message)
    @output.puts(message)
    @output.flush
    File.open(@env['GITHUB_STEP_SUMMARY'], 'a') { |file| file.puts("#{message}\n\n") } if @env['GITHUB_STEP_SUMMARY']
  end
end

if $PROGRAM_NAME == __FILE__
  runner = ImagePublisher.new
  begin
    unless %w[check prepare publish].include?(ARGV.first)
      raise ImagePublisher::Error, 'Expected check, prepare, or publish.'
    end

    runner.public_send(ARGV.first)
  rescue ImagePublisher::Error, JSON::ParserError, KeyError, SystemCallError => e
    runner.summary("Image automation failed: #{e.message}. " \
                   'Tags may be partially updated; inspect the run and rerun manually.')
    exit 1
  end
end
