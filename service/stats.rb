module Service
  # The Stats class provides methods to update various port values and timestamps in the stats table
  # of a SQLite3 database.
  # It includes methods to set the proton current port, OPN current port, OPN updated timestamp, Qbit current port,
  # and Qbit updated timestamp.
  # All database operations are executed through a private db_execute method.
  class Stats
    def set_proton_current_port(port)
      db_execute('update stats set proton_current_port = ? where id = 1', port)
    end

    def set_opn_current_port(port)
      db_execute('update stats set opn_current_port = ? where id = 1', port)
    end

    def set_opn_updated_at
      db_execute('update stats set opn_updated_at = ? where id = 1', Time.now.to_s)
    end

    def set_qbit_current_port(port)
      db_execute('update stats set qbit_current_port = ? where id = 1', port)
    end

    def set_qbit_updated_at
      db_execute('update stats set qbit_updated_at = ? where id = 1', Time.now.to_s)
    end

    private

    def db_execute(query, param)
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute(query, param)
      end
    end
  end
end
