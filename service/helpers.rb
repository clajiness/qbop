require 'time'

module Service
  # The Helpers class provides utility methods for accessing environment variables
  # and parsing specific configuration values used in the application.
  class Helpers # rubocop:disable Metrics/ClassLength
    HISTORY_PAGE_SIZES = [25, 50, 100].freeze

    def env_variables # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      {
        ui_mode: format_ui_mode(ENV['UI_MODE'] || 'dark'),
        script_version: app_version,
        commit_sha: commit_sha,
        loop_freq: validate_loop_frequency(ENV['LOOP_FREQ'] || 45),
        required_attempts: validate_required_attempts(ENV['REQUIRED_ATTEMPTS'] || 3),
        proton_gateway: ENV['PROTON_GATEWAY'] || '10.2.0.1',
        opnsense_skip: ENV['OPN_SKIP'] || 'false',
        opnsense_interface_addr: ENV['OPN_INTERFACE_ADDR'],
        opnsense_api_key: ENV['OPN_API_KEY'],
        opnsense_api_secret: ENV['OPN_API_SECRET'],
        opnsense_alias_name: ENV['OPN_PROTON_ALIAS_NAME'],
        opnsense_ssl_verify: true?(ENV['OPN_SSL_VERIFY'] || 'false'),
        qbit_skip: ENV['QBIT_SKIP'] || 'false',
        qbit_addr: ENV['QBIT_ADDR'],
        qbit_api_key: ENV['QBIT_API_KEY'],
        qbit_user: ENV['QBIT_USER'],
        qbit_pass: ENV['QBIT_PASS'],
        qbit_ssl_verify: true?(ENV['QBIT_SSL_VERIFY'] || 'false'),
        log_lines: ENV['LOG_LINES'] || 50,
        log_reverse: ENV['LOG_REVERSE'] || 'false',
        log_to_stdout: ENV['LOG_TO_STDOUT'] || 'false',
        web_auth_enabled: ENV['WEB_AUTH_ENABLED'] || 'true',
        basic_auth_enabled: ENV['BASIC_AUTH_ENABLED'] || 'false',
        basic_auth_user: ENV['BASIC_AUTH_USER'] || 'admin',
        basic_auth_pass: ENV['BASIC_AUTH_PASS'] || 'admin'
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
      if loop_freq&.to_i&.positive?
        loop_freq&.to_i
      else
        45
      end
    end

    def validate_required_attempts(required_attempts)
      if required_attempts&.to_i&.between?(1, 10)
        required_attempts&.to_i
      else
        3
      end
    end

    def validate_refresh_interval(refresh)
      return 0 if refresh.nil?

      refresh.to_i.clamp(0, 3600)
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

      !!(last_checked_time && last_checked_time >= (Time.now - ((ENV['LOOP_FREQ'] || 45).to_i * 3)))
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

      output = File.readlines('log/qbop.log').last(validate_log_lines(log_lines))
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
      else
        return 'unknown provider'
      end

      stdout.empty? ? stderr&.tr('"', '') : stdout&.tr('"', '')
    rescue StandardError
      'error retrieving public ip'
    end

    def logger_instance
      default = Logger.new('log/qbop.log', 10, 5_120_000)

      if true?(env_variables[:log_to_stdout])
        Logger.new($stdout)
      else
        default
      end
    rescue StandardError
      default
    end

    private

    def time_value(value)
      return value if value.is_a?(Time)
      return value.to_time if value.respond_to?(:to_time)

      Time.parse(value.to_s)
    rescue StandardError
      nil
    end
  end
end
