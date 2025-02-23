module Service
  class DbMigration # rubocop:disable Style/Documentation
    def initialize
      version = check_user_version
      run_migrations(version)
    end

    private

    def check_user_version
      user_version = 0

      SQLite3::Database.open 'data/prod.db' do |db|
        user_version = db.execute('pragma user_version;').flatten.first
      end

      user_version
    end

    def run_migrations(version)
      case version
      when 0
        migration_0
      else
        puts 'No migrations to run.'
      end
    end

    def migration_0 # rubocop:disable Metrics/MethodLength,Naming/VariableNumber
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute 'ALTER TABLE stats ADD COLUMN proton_last_checked TEXT'
        db.execute 'ALTER TABLE stats ADD COLUMN opn_last_checked TEXT'
        db.execute 'ALTER TABLE stats ADD COLUMN qbit_last_checked TEXT'
        db.execute 'update stats
      set proton_last_checked = ?,
      opn_last_checked = ?,
      qbit_last_checked = ?
      where id = 1', %w[
        unknown
        unknown
        unknown
      ]
        db.execute 'pragma user_version = 1'
      end
    end
  end
end
