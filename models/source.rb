class Source < Sequel::Model # rubocop:disable Style/Documentation
  one_to_one :counter
  one_to_one :stat

  # stats methods
  def set_last_checked
    stat.update(last_checked: Time.now)
  end

  def get_last_checked
    stat.last_checked
  end

  def set_current_port(port)
    stat.update(current_port: port)
  end

  def get_current_port
    stat.current_port
  end

  def set_updated_at
    stat.update(updated_at: Time.now)
  end

  def get_updated_at
    stat.updated_at
  end

  def updated?
    !get_updated_at.nil?
  end

  def set_same_port
    return unless get_last_checked && get_updated_at

    seconds = get_last_checked - get_updated_at
    return unless seconds > get_same_port

    stat.update(same_port: seconds.to_i)
  end

  def get_same_port
    stat.same_port
  end

  # counters methods

  def change
    counter.update(change: true)
  end

  def reset_change
    counter.update(change: false)
  end

  def change?
    counter.change
  end

  def increment_attempt
    counter.update(attempt: counter.attempt + 1)
  end

  def reset_attempt
    counter.update(attempt: 0)
  end

  def attempt
    counter.attempt
  end

  # initialize methods

  def seed_tables
    Stat.find_or_create(source_id: id) do |record|
      record.current_port = 0
      record.same_port = 0
    end

    Counter.find_or_create(source_id: id) do |record|
      record.attempt = 0
      record.change = false
    end

    associations.delete(:stat)
    associations.delete(:counter)
  end
end
