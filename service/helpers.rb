module Service
  # The Helpers class provides utility methods for accessing environment variables
  # and parsing specific configuration values used in the application.
  class Helpers # rubocop:disable Metrics/ClassLength
    def env_variables # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      {
        ui_mode: format_ui_mode(ENV['UI_MODE']),
        script_version: ENV['VERSION'],
        loop_freq: validate_loop_frequency(ENV['LOOP_FREQ'] || 45),
        required_attempts: validate_required_attempts(ENV['REQUIRED_ATTEMPTS'] || 3),
        proton_gateway: ENV['PROTON_GATEWAY'] || '10.2.0.1',
        opnsense_skip: ENV['OPN_SKIP'] || 'false',
        opnsense_interface_addr: ENV['OPN_INTERFACE_ADDR'],
        opnsense_api_key: ENV['OPN_API_KEY'],
        opnsense_api_secret: ENV['OPN_API_SECRET'],
        opnsense_alias_name: ENV['OPN_PROTON_ALIAS_NAME'],
        qbit_skip: ENV['QBIT_SKIP'] || 'false',
        qbit_addr: ENV['QBIT_ADDR'],
        qbit_user: ENV['QBIT_USER'],
        qbit_pass: ENV['QBIT_PASS'],
        log_lines: ENV['LOG_LINES'] || 50,
        log_reverse: ENV['LOG_REVERSE'] || 'false',
        log_to_stdout: ENV['LOG_TO_STDOUT'] || 'false'
      }
    end

    def format_ui_mode(ui_mode)
      ui_mode&.to_s&.downcase
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
      last_checked_time = Time.new(last_checked)
      last_updated_time = Time.new(last_updated)

      seconds = last_checked_time - last_updated_time

      seconds.to_i
    rescue StandardError
      'unknown'
    end

    def time_delta_to_s(last_checked, last_updated)
      last_checked_time = Time.new(last_checked)
      last_updated_time = Time.new(last_updated)

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
      Time.new(last_checked) >= (Time.now - ((ENV['LOOP_FREQ'] || 45).to_i * 3))
    rescue StandardError
      false
    end

    def update_available?
      newest_tag = Service::Github.new.get_most_recent_tag[1..]
      app_tag = ENV['VERSION'][1..]

      Gem::Version.new(newest_tag) > Gem::Version.new(app_tag) if newest_tag && app_tag
    rescue StandardError
      false
    end

    def log_lines_to_a(log_lines)
      output = []

      File.readlines('log/qbop.log').last(log_lines.to_i).each do |line|
        output << line
      end

      formatted_output = true?(env_variables[:log_reverse]) ? output.reverse : output

      last_line = formatted_output.pop
      formatted_output << last_line.strip
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
        "echo #{private_key.shellescape} | wg pubkey"
      )

      stdout.empty? ? stderr.chomp : stdout.chomp
    rescue StandardError
      'error generating public key'
    end

    def get_public_ip(provider) # rubocop:disable Metrics/MethodLength,Metrics/CyclomaticComplexity
      case provider
      when 'akamai'
        stdout, stderr = Open3.capture3('timeout 5 dig whoami.akamai.net. @ns1-1.akamaitech.net. +short')
      when 'cloudflare'
        stdout, stderr = Open3.capture3('timeout 5 dig whoami.cloudflare ch txt @1.1.1.1 +short')
      when 'google'
        stdout, stderr = Open3.capture3('timeout 5 dig o-o.myaddr.l.google.com txt @ns1.google.com +short')
      when 'opendns'
        stdout, stderr = Open3.capture3('timeout 5 dig myip.opendns.com @dns.opendns.com +short')
      else
        return 'unknown provider'
      end

      stdout.empty? ? stderr&.tr('"', '') : "#{provider} -> #{stdout&.tr('"', '')}"
    rescue StandardError
      'error retrieving public IP'
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
  end
end
