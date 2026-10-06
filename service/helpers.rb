require 'time'
require_relative 'event_logger'
require_relative 'gluetun_url'
require_relative 'settings'

module Service
  # The Helpers class provides utility methods for accessing environment variables
  # and parsing specific configuration values used in the application.
  class Helpers # rubocop:disable Metrics/ClassLength
    HISTORY_PAGE_SIZES = [25, 50, 100].freeze
    PUBLIC_IP_PROVIDERS = %w[akamai cloudflare google opendns].freeze

    def env_variables # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      {
        ui_mode: format_ui_mode(ENV['UI_MODE'] || 'dark'),
        script_version: app_version,
        commit_sha: commit_sha,
        loop_freq: loop_frequency,
        required_attempts: settings.value(:required_attempts),
        port_source: settings.value(:port_source),
        proton_gateway: settings.value(:proton_gateway),
        gluetun_addr: environment_value('GLUETUN_ADDR', 'http://gluetun:8000'),
        gluetun_api_key: environment_value('GLUETUN_API_KEY'),
        gluetun_user: environment_value('GLUETUN_USER'),
        gluetun_pass: environment_value('GLUETUN_PASS'),
        gluetun_ssl_verify: true?(ENV['GLUETUN_SSL_VERIFY'] || 'false'),
        opnsense_skip: ENV['OPN_SKIP'] || 'false',
        opnsense_interface_addr: ENV['OPN_INTERFACE_ADDR'],
        opnsense_api_key: ENV['OPN_API_KEY'],
        opnsense_api_secret: ENV['OPN_API_SECRET'],
        opnsense_alias_name: environment_value('OPN_ALIAS_NAME', environment_value('OPN_PROTON_ALIAS_NAME')),
        opnsense_ssl_verify: true?(ENV['OPN_SSL_VERIFY'] || 'false'),
        qbit_skip: ENV['QBIT_SKIP'] || 'false',
        qbit_addr: ENV['QBIT_ADDR'],
        qbit_api_key: environment_value('QBIT_API_KEY'),
        qbit_user: ENV['QBIT_USER'],
        qbit_pass: ENV['QBIT_PASS'],
        qbit_ssl_verify: true?(ENV['QBIT_SSL_VERIFY'] || 'false'),
        log_lines: ENV['LOG_LINES'] || 50,
        log_reverse: ENV['LOG_REVERSE'] || 'false',
        log_to_stdout: ENV['LOG_TO_STDOUT'] || 'false',
        web_auth_enabled: ENV['WEB_AUTH_ENABLED'] || 'true'
      }
    end

    def format_ui_mode(ui_mode)
      ui_mode&.to_s&.downcase
    end

    def app_version
      ENV.fetch('VERSION', 'development')
    end

    def commit_sha
      ENV.fetch('COMMIT_SHA', 'unknown')
    end

    def build_date
      ENV.fetch('BUILD_DATE', 'unknown')
    end

    def short_commit_sha
      return commit_sha if commit_sha == 'unknown'

      commit_sha[0, 12]
    end

    def release_build?
      app_version.match?(/\Av\d+\.\d+\.\d+\z/)
    end

    def main_build?
      app_version == 'main'
    end

    def validate_loop_frequency(loop_freq)
      Settings.validate_loop_frequency(loop_freq)
    end

    def loop_frequency
      settings.value(:loop_freq)
    end

    def validate_required_attempts(required_attempts)
      Settings.validate_required_attempts(required_attempts)
    end

    def validate_log_lines(log_lines, default = env_variables[:log_lines])
      lines = log_lines.to_i
      return lines.clamp(1, 5000) if lines.positive?

      default_lines = default.to_i
      default_lines.positive? ? default_lines.clamp(1, 5000) : 50
    end

    def validate_page(page)
      page = page.to_i
      page.positive? ? page : 1
    end

    def validate_history_page_size(per_page)
      per_page = per_page.to_i
      HISTORY_PAGE_SIZES.include?(per_page) ? per_page : HISTORY_PAGE_SIZES.first
    end

    def format_log_direction(direction, default_reverse: false)
      return default_reverse ? 'desc' : 'asc' if direction.nil? || direction.to_s.strip.empty?

      case direction.to_s.downcase
      when 'asc', 'desc'
        direction.to_s.downcase
      else
        default_reverse ? 'desc' : 'asc'
      end
    end

    def true?(obj)
      obj&.to_s&.downcase == 'true'
    end

    def redact_url_credentials(url)
      uri = GluetunUrl.parse(url)
      uri.userinfo = '***' if uri.userinfo
      uri.to_s
    rescue URI::InvalidURIError, GluetunUrl::InvalidBaseUrl
      '[invalid URL]'
    end

    def get_db_version
      info = DB[:schema_info]
      info.first[:version] if info.any?
    rescue StandardError
      'unknown'
    end

    def time_delta(last_checked, last_updated)
      last_checked_time = time_value(last_checked)
      last_updated_time = time_value(last_updated)
      return 'unknown' unless last_checked_time && last_updated_time

      seconds = last_checked_time - last_updated_time

      seconds.to_i
    rescue StandardError
      'unknown'
    end

    def time_delta_to_s(last_checked, last_updated)
      last_checked_time = time_value(last_checked)
      last_updated_time = time_value(last_updated)
      return 'unknown' unless last_checked_time && last_updated_time

      seconds = last_checked_time - last_updated_time

      mm, ss = seconds.to_i.divmod(60)
      hh, mm = mm.divmod(60)
      dd, hh = hh.divmod(24)

      "#{dd}d, #{hh}h, #{mm}m, #{ss}s"
    rescue StandardError
      'unknown'
    end

    def seconds_to_s(seconds)
      mm, ss = seconds.to_i.divmod(60)
      hh, mm = mm.divmod(60)
      dd, hh = hh.divmod(24)

      "#{dd}d, #{hh}h, #{mm}m, #{ss}s"
    rescue StandardError
      'unknown'
    end

    def connected_to_service?(last_checked)
      last_checked_time = time_value(last_checked)

      !!(last_checked_time && last_checked_time >= (Time.now - (loop_frequency * 3)))
    rescue StandardError
      false
    end

    def update_available?(tag = nil)
      tag ||= Service::Github.new.get_most_recent_tag
      newest_tag = tag&.delete_prefix('v')
      app_tag = app_version.delete_prefix('v')
      return false unless newest_tag && release_build?

      Gem::Version.new(newest_tag) > Gem::Version.new(app_tag)
    rescue StandardError
      false
    end

    def log_lines_to_a(log_lines, reverse = nil)
      return [] if log_lines.nil?

      output = tail_lines('log/qbop.log', validate_log_lines(log_lines))
      reverse = true?(env_variables[:log_reverse]) if reverse.nil?
      output.reverse! if reverse

      output[-1] = output.last.strip if output.any?
      output
    rescue StandardError
      []
    end

    def gemfile_to_a
      gemfile = []

      File.readlines('Gemfile').each do |line|
        gemfile << line
      end

      last_line = gemfile.pop
      gemfile << last_line.strip
    rescue StandardError
      []
    end

    def generate_wg_public_key(private_key)
      stdout, stderr = Open3.capture3(
        'wg', 'pubkey', stdin_data: "#{private_key}\n"
      )

      stdout.empty? ? stderr.chomp : stdout.chomp
    rescue StandardError
      'error generating public key'
    end

    def get_public_ip(provider) # rubocop:disable Metrics/MethodLength,Metrics/CyclomaticComplexity
      provider = public_ip_provider(provider)
      return 'unknown provider' unless provider

      case provider
      when 'akamai'
        stdout, stderr = Open3.capture3('timeout', '5', 'dig', 'whoami.akamai.net.', '@ns1-1.akamaitech.net.', '+short')
      when 'cloudflare'
        stdout, stderr = Open3.capture3('timeout', '5', 'dig', 'whoami.cloudflare', 'ch', 'txt', '@1.1.1.1', '+short')
      when 'google'
        stdout, stderr = Open3.capture3(
          'timeout', '5', 'dig', 'o-o.myaddr.l.google.com', 'txt', '@ns1.google.com', '+short'
        )
      when 'opendns'
        stdout, stderr = Open3.capture3('timeout', '5', 'dig', 'myip.opendns.com', '@dns.opendns.com', '+short')
      end

      stdout.empty? ? stderr&.tr('"', '') : stdout&.tr('"', '')
    rescue StandardError
      'error retrieving public ip'
    end

    def public_ip_provider(provider)
      provider = provider.to_s.strip.downcase
      provider if PUBLIC_IP_PROVIDERS.include?(provider)
    end

    def logger_instance
      default = EventLogger.new('log/qbop.log', 10, 5_120_000)

      if true?(env_variables[:log_to_stdout])
        Logger.new($stdout)
      else
        default
      end
    rescue StandardError
      default
    end

    private

    def settings
      @settings ||= Settings.new
    end

    def tail_lines(path, line_limit)
      File.foreach(path).each_with_object([]) do |line, output|
        output.shift if output.length == line_limit
        output << line
      end
    end

    def environment_value(name, default = nil)
      value = ENV[name]
      value.nil? || value.strip.empty? ? default : value
    end

    def time_value(value)
      return value if value.is_a?(Time)
      return value.to_time if value.respond_to?(:to_time)

      Time.parse(value.to_s)
    rescue StandardError
      nil
    end
  end
end
