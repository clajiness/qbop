module Service
  class DbInitialization # rubocop:disable Style/Documentation
    def initialize
      @required_attempts = ENV['REQUIRED_ATTEMPTS'] || 3
      @opnsense_attempt = 0
      @opnsense_change = 'false'
      @qbit_attempt = 0
      @qbit_change = 'false'

      db = create_db
      create_tables(db)
      populate_tables(db)
    end

    private

    def create_db
      SQLite3::Database.new 'data/prod.db'
    end

    def create_tables(db) # rubocop:disable Metrics/MethodLength
      db.execute <<-SQL
        create table counters (
          ID INTEGER PRIMARY KEY AUTOINCREMENT,
          required_attempts INTEGER,
          opnsense_attempt INTEGER,
          opnsense_change BOOLEAN,
          qbit_attempt INTEGER,
          qbit_change BOOLEAN
        );
      SQL
      db.execute <<-SQL
        create table stats (
          ID INTEGER PRIMARY KEY AUTOINCREMENT,
          current_port INTEGER,
          updated_at TEXT
        );
      SQL
    end

    def populate_tables(db) # rubocop:disable Metrics/MethodLength
      db.execute 'insert into counters (
        required_attempts,
        opnsense_attempt,
        opnsense_change,
        qbit_attempt,
        qbit_change
        ) values (?, ?, ?, ?, ?)', [
          @required_attempts,
          @opnsense_attempt,
          @opnsense_change,
          @qbit_attempt,
          @qbit_change
        ]

      db.execute 'insert into stats (current_port, updated_at) values (?, ?)', [1234, Time.now.to_s]
    end
  end
end
