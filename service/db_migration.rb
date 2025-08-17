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

    def run_migrations(version) # rubocop:disable Metrics/MethodLength
      loop do
        case version
        when 0
          migration1
          version += 1
        when 1
          migration2
          version += 1
        when 2
          migration3
          version += 1
        else
          break
        end
      end
    end

    def migration1 # rubocop:disable Metrics/MethodLength
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute 'ALTER TABLE stats ADD COLUMN proton_last_checked TEXT'
        db.execute 'ALTER TABLE stats ADD COLUMN opn_last_checked TEXT'
        db.execute 'ALTER TABLE stats ADD COLUMN qbit_last_checked TEXT'
        db.execute 'UPDATE stats
      SET proton_last_checked = ?,
      opn_last_checked = ?,
      qbit_last_checked = ?
      WHERE id = 1', %w[
        unknown
        unknown
        unknown
      ]
        db.execute 'pragma user_version = 1'
      end
    end

    def migration2 # rubocop:disable Metrics/MethodLength
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute 'ALTER TABLE stats ADD COLUMN job_started_at TEXT'
        db.execute 'ALTER TABLE stats ADD COLUMN proton_updated_at TEXT'
        db.execute 'ALTER TABLE stats ADD COLUMN proton_same_port INTEGER'
        db.execute 'ALTER TABLE stats ADD COLUMN opn_same_port INTEGER'
        db.execute 'ALTER TABLE stats ADD COLUMN qbit_same_port INTEGER'
        db.execute 'UPDATE stats
      SET job_started_at = ?,
      proton_updated_at = ?,
      proton_same_port = ?,
      opn_same_port = ?,
      qbit_same_port = ?
      WHERE id = 1', [
        'unknown',
        'unknown',
        0,
        0,
        0
      ]
        db.execute 'pragma user_version = 2'
      end
    end

    def migration3 # rubocop:disable Metrics/MethodLength
      SQLite3::Database.open 'data/prod.db' do |db|
        db.execute <<-SQL
          create table notifications (
            ID INTEGER PRIMARY KEY AUTOINCREMENT,
            update_available BOOLEAN,
            update_version TEXT
          );
        SQL
        db.execute 'insert into notifications (
          update_available,
          update_version
          ) values (?, ?)', %w[
            false
            unknown
          ]
        db.execute 'pragma user_version = 3'
      end
    end
  end
end
