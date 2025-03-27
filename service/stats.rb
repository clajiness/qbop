module Service
  # The Stats class provides methods to update various port values and timestamps in the stats table
  # of a SQLite3 database.
  # It includes methods to set the proton current port, OPN current port, OPN updated timestamp, Qbit current port,
  # and Qbit updated timestamp.
  # All database operations are executed through a private db_execute method.
  class Stats
    def get_proton_current_port
      db_execute('select proton_current_port from stats where id = 1').flatten.first
    end

    def set_proton_current_port(port)
      db_execute_with_param('update stats set proton_current_port = ? where id = 1', port)
    end

    def get_proton_last_checked
      db_execute('select proton_last_checked from stats where id = 1').flatten.first
    end

    def set_proton_last_checked
      db_execute_with_param('update stats set proton_last_checked = ? where id = 1', Time.now.to_s)
    end

    def get_proton_updated_at
      db_execute('select proton_updated_at from stats where id = 1').flatten.first
    end

    def set_proton_updated_at
      db_execute_with_param('update stats set proton_updated_at = ? where id = 1', Time.now.to_s)
    end

    def get_proton_same_port
      db_execute('select proton_same_port from stats where id = 1').flatten.first
    end

    def set_proton_same_port
      seconds = Time.now - Time.new(get_proton_updated_at)
      db_execute_with_param('update stats set proton_same_port = ? where id = 1', seconds) if seconds > get_opn_same_port
    end

    def get_opn_current_port
      db_execute('select opn_current_port from stats where id = 1').flatten.first
    end

    def set_opn_current_port(port)
      db_execute_with_param('update stats set opn_current_port = ? where id = 1', port)
    end

    def get_opn_last_checked
      db_execute('select opn_last_checked from stats where id = 1').flatten.first
    end

    def set_opn_last_checked
      db_execute_with_param('update stats set opn_last_checked = ? where id = 1', Time.now.to_s)
    end

    def get_opn_updated_at
      db_execute('select opn_updated_at from stats where id = 1').flatten.first
    end

    def set_opn_updated_at
      db_execute_with_param('update stats set opn_updated_at = ? where id = 1', Time.now.to_s)
    end

    def get_opn_same_port
      db_execute('select opn_same_port from stats where id = 1').flatten.first
    end

    def set_opn_same_port
      seconds = Time.now - Time.new(get_opn_updated_at)
      db_execute_with_param('update stats set opn_same_port = ? where id = 1', seconds) if seconds > get_opn_same_port
    end

    def get_qbit_current_port
      db_execute('select qbit_current_port from stats where id = 1').flatten.first
    end

    def set_qbit_current_port(port)
      db_execute_with_param('update stats set qbit_current_port = ? where id = 1', port)
    end

    def get_qbit_last_checked
      db_execute('select qbit_last_checked from stats where id = 1').flatten.first
    end

    def set_qbit_last_checked
      db_execute_with_param('update stats set qbit_last_checked = ? where id = 1', Time.now.to_s)
    end

    def get_qbit_updated_at
      db_execute('select qbit_updated_at from stats where id = 1').flatten.first
    end

    def set_qbit_updated_at
      db_execute_with_param('update stats set qbit_updated_at = ? where id = 1', Time.now.to_s)
    end

    def get_qbit_same_port
      db_execute('select qbit_same_port from stats where id = 1').flatten.first
    end

    def set_qbit_same_port
      seconds = Time.now - Time.new(get_qbit_updated_at)
      db_execute_with_param('update stats set qbit_same_port = ? where id = 1', seconds) if seconds > get_opn_same_port
    end

    def get_job_started_at
      db_execute('select job_started_at from stats where id = 1').flatten.first
    end

    def set_job_started_at
      db_execute_with_param('update stats set job_started_at = ? where id = 1', Time.now.to_s)
    end

    def get_all
      SQLite3::Database.open 'data/prod.db' do |db|
        db.results_as_hash = true
        db.execute('select * from stats where id = 1').first
      end
    end

    private

    def db_execute(query)
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute(query)
      end
    end

    def db_execute_with_param(query, param)
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute(query, param)
      end
    end
  end
end
