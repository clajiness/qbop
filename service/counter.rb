module Service
  # tracks the number of attempts to change the port in opnsense and qBit
  class Counter
    def required_attempts
      db_execute('select required_attempts from counters where id = 1').flatten.first
    end

    def opnsense_attempt
      db_execute('select opnsense_attempt from counters where id = 1').flatten.first
    end

    def qbit_attempt
      db_execute('select qbit_attempt from counters where id = 1').flatten.first
    end

    def opnsense_change?
      change = db_execute('select opnsense_change from counters where id = 1').flatten.first
      change == 1
    end

    def qbit_change?
      change = db_execute('select qbit_change from counters where id = 1').flatten.first
      change == 1
    end

    def increment_opnsense_attempt
      db_execute('update counters set opnsense_attempt = opnsense_attempt + 1 where id = 1')
    end

    def increment_qbit_attempt
      db_execute('update counters set qbit_attempt = qbit_attempt + 1 where id = 1')
    end

    def reset_opnsense_attempt
      db_execute('update counters set opnsense_attempt = 0 where id = 1')
    end

    def reset_qbit_attempt
      db_execute('update counters set qbit_attempt = 0 where id = 1')
    end

    def change_opnsense
      db_execute('update counters set opnsense_change = true where id = 1')
    end

    def change_qbit
      db_execute('update counters set qbit_change = true where id = 1')
    end

    def reset_opnsense_change
      db_execute('update counters set opnsense_change = false where id = 1')
    end

    def reset_qbit_change
      db_execute('update counters set qbit_change = false where id = 1')
    end

    private

    def db_execute(query)
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute(query)
      end
    end
  end
end
