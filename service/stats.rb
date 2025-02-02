module Service
  class Stats # rubocop:disable Style/Documentation
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
