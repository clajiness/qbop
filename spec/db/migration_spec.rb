require 'bundler/setup'
Bundler.require(:default)
require 'tmpdir'

RSpec.describe 'database migrations' do # rubocop:disable Metrics/BlockLength
  def run_migrations(db)
    Sequel.extension :migration
    Sequel::Migrator.run(db, 'db/migrate')
  end

  def unique_source_id_index?(db, table)
    unique_index?(db, table, [:source_id])
  end

  def unique_index?(db, table, columns)
    db.indexes(table).any? { |_name, index| index[:unique] && index[:columns] == columns }
  end

  it 'creates the current schema from scratch' do
    db = Sequel.sqlite

    run_migrations(db)
    stats_schema = db.schema(:stats).to_h

    expect(stats_schema[:updated_at][:type]).to eq(:datetime)
    expect(stats_schema[:last_checked][:type]).to eq(:datetime)
    expect(stats_schema[:source_id][:allow_null]).to eq(false)
    expect(unique_source_id_index?(db, :stats)).to eq(true)
    expect(unique_source_id_index?(db, :counters)).to eq(true)
    expect(db.table_exists?(:port_transitions)).to eq(true)
    expect(db.schema(:port_transitions).to_h).to include(
      detected_at: include(type: :datetime, allow_null: false),
      opnsense_error_at: include(type: :datetime, allow_null: true),
      qbit_error_at: include(type: :datetime, allow_null: true)
    )
    expect(db.table_exists?(:accounts)).to eq(true)
    expect(db.table_exists?(:account_password_hashes)).to eq(true)
    expect(db.table_exists?(:api_keys)).to eq(true)
  end

  it 'adds nullable error timestamps without inferring errors for existing transitions' do
    db = Sequel.sqlite
    Sequel.extension :migration
    Sequel::Migrator.run(db, 'db/migrate', target: 5)
    transition_id = db[:port_transitions].insert(
      previous_port: 12_345,
      new_port: 23_456,
      detected_at: Time.now,
      opnsense_skipped: false,
      qbit_skipped: false
    )

    run_migrations(db)

    transition = db[:port_transitions][id: transition_id]
    expect(transition[:opnsense_error_at]).to be_nil
    expect(transition[:qbit_error_at]).to be_nil
  end

  it 'creates standalone API keys with unique digests and optional last use' do
    db = Sequel.sqlite
    run_migrations(db)
    schema = db.schema(:api_keys).to_h

    expect(schema).to include(
      name: include(allow_null: false),
      token_digest: include(allow_null: false),
      token_prefix: include(allow_null: false),
      created_at: include(type: :datetime, allow_null: false),
      last_used_at: include(type: :datetime, allow_null: true)
    )
    expect(unique_index?(db, :api_keys, [:token_digest])).to eq(true)

    attributes = {
      name: 'automation', token_digest: 'digest', token_prefix: 'qbop_12345678', created_at: Time.now
    }
    db[:api_keys].insert(attributes)

    expect { db[:api_keys].insert(attributes.merge(name: 'other')) }
      .to raise_error(Sequel::UniqueConstraintViolation)
    expect(db[:accounts].count).to eq(0)
  end

  it 'creates the minimal Rodauth schema with unique login and singleton indexes' do
    db = Sequel.sqlite

    run_migrations(db)

    expect(db.schema(:accounts).to_h).to include(
      email: include(allow_null: false),
      single_account_key: include(allow_null: false, ruby_default: 1)
    )
    expect(db.schema(:account_password_hashes).to_h[:password_hash][:allow_null]).to eq(false)
    expect(unique_index?(db, :accounts, [:email])).to eq(true)
    expect(unique_index?(db, :accounts, [:single_account_key])).to eq(true)
  end

  it 'enforces the single-account invariant in the database' do
    db = Sequel.sqlite
    run_migrations(db)

    db[:accounts].insert(email: 'admin@example.com')

    expect { db[:accounts].insert(email: 'other@example.com') }
      .to raise_error(Sequel::UniqueConstraintViolation)
    expect { db[:accounts].insert(email: 'other@example.com', single_account_key: 2) }
      .to raise_error(Sequel::CheckConstraintViolation)
    expect(db[:accounts].count).to eq(1)
  end

  it 'enforces case-insensitive login uniqueness independently of the singleton guard' do
    db = Sequel.sqlite
    run_migrations(db)
    singleton_index = db.indexes(:accounts).find do |_name, index|
      index[:columns] == [:single_account_key]
    end.first
    db.drop_index(:accounts, :single_account_key, name: singleton_index)
    db[:accounts].insert(email: 'Admin@example.com')

    expect { db[:accounts].insert(email: 'admin@example.com') }
      .to raise_error(Sequel::UniqueConstraintViolation)
  end

  it 'allows only one of two competing account inserts to succeed' do
    database_path = File.join(Dir.mktmpdir, 'qbop.sqlite3')
    db = Sequel.sqlite(database_path, max_connections: 2, timeout: 1_000)
    run_migrations(db)
    ready = Queue.new
    start = Queue.new
    results = Queue.new

    threads = %w[first@example.com second@example.com].map do |email|
      Thread.new do
        ready << true
        start.pop
        db[:accounts].insert(email: email)
        results << :created
      rescue Sequel::UniqueConstraintViolation
        results << :rejected
      rescue StandardError => e
        results << e.class
      end
    end

    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)

    expect(2.times.map { results.pop }.sort).to eq(%i[created rejected])
    expect(db[:accounts].count).to eq(1)
  end

  it 'normalizes a legacy version 1 schema' do
    db = Sequel.sqlite
    create_legacy_schema(db)

    run_migrations(db)

    expect(db[:stats].where(source_id: 1).count).to eq(1)
    expect(db[:counters].where(source_id: 1).count).to eq(1)
    expect(db[:stats].first[:updated_at]).to eq(nil)
    expect(unique_source_id_index?(db, :stats)).to eq(true)
    expect(unique_source_id_index?(db, :counters)).to eq(true)
  end

  def create_legacy_schema(db) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    db.create_table(:schema_info) { Integer :version, null: false, default: 0 }
    db[:schema_info].insert(version: 1)

    db.create_table(:sources) do
      primary_key :id
      String :name, null: false, unique: true
    end

    db.create_table(:stats) do
      primary_key :id
      foreign_key :source_id, :sources
      Integer :current_port, default: 0, null: false
      Integer :same_port, default: 0, null: false
      String :updated_at
      String :last_checked
    end

    db.create_table(:counters) do
      primary_key :id
      foreign_key :source_id, :sources
      Integer :attempt, default: 0, null: false
      Boolean :change, default: false, null: false
    end

    db.create_table(:notifications) do
      primary_key :id
      String :name, null: false, unique: true
      String :info
      Boolean :active, default: false
    end

    db[:sources].insert(id: 1, name: 'proton')
    db[:stats].insert(source_id: 1, updated_at: 'unknown', last_checked: Time.now.to_s)
    db[:stats].insert(source_id: 1, updated_at: Time.now.to_s, last_checked: Time.now.to_s)
    db[:counters].insert(source_id: 1)
    db[:counters].insert(source_id: 1)
  end
end
