module Service
  class Notification # rubocop:disable Style/Documentation
    def get_update_available
      db_execute('select update_available from notifications where id = 1').flatten.first
    end

    def set_update_available(available)
      db_execute_with_param('update notifications set update_available = ? where id = 1', available.to_s)
    end

    def get_update_version
      db_execute('select update_version from notifications where id = 1').flatten.first
    end

    def set_update_version(version)
      db_execute_with_param('update notifications set update_version = ? where id = 1', version)
    end

    def get_all
      SQLite3::Database.open 'data/prod.db' do |db|
        db.results_as_hash = true
        db.execute('select * from notifications where id = 1').first
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
