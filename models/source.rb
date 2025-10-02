class Source < Sequel::Model # rubocop:disable Style/Documentation
  one_to_many :counters
  one_to_many :stats

  # stats methods
  def set_last_checked
    stats.first.update(last_checked: Time.now.to_s)
  end

  def get_last_checked
    stats.first.last_checked
  end

  def set_current_port(port)
    stats.first.update(current_port: port)
  end

  def get_current_port
    stats.first.current_port
  end

  def set_updated_at
    stats.first.update(updated_at: Time.now.to_s)
  end

  def get_updated_at
    stats.first.updated_at
  end

  def set_same_port
    seconds = Time.now - Time.new(get_updated_at)
    return unless seconds > get_same_port

    stats.first.update(same_port: seconds.to_i)
  end

  def get_same_port
    stats.first.same_port
  end

  # counters methods

  def change
    counters.first.update(change: true)
  end

  def reset_change
    counters.first.update(change: false)
  end

  def change?
    counters.first.change
  end

  def increment_attempt
    counters.first.update(attempt: counters.first.attempt + 1)
  end

  def reset_attempt
    counters.first.update(attempt: 0)
  end

  def attempt
    counters.first.attempt
  end

  # initialize methods

  def seed_tables
    add_stat(current_port: 0, same_port: 0, updated_at: 'unknown', last_checked: 'unknown') if stats.first.nil?
    add_counter(attempt: 0, change: false) if counters.first.nil?
  end
end
