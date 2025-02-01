module Service
  class Stats # rubocop:disable Style/Documentation
    def set_proton_current_port(port)
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute('update stats set proton_current_port = ? where id = 1', port)
      end
    end

    def set_opn_current_port(port)
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute('update stats set opn_current_port = ? where id = 1', port)
      end
    end

    def set_opn_updated_at
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute('update stats set opn_updated_at = ? where id = 1', Time.now.to_s)
      end
    end

    def set_qbit_current_port(port)
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute('update stats set qbit_current_port = ? where id = 1', port)
      end
    end

    def set_qbit_updated_at
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute('update stats set qbit_updated_at = ? where id = 1', Time.now.to_s)
      end
    end
  end
end
