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
    expect(db.schema(:counters).to_h).to include(
      pending_apply_port: include(type: :integer, allow_null: true, ruby_default: nil),
      pending_apply_transition_ids: include(type: :string, allow_null: true, ruby_default: nil)
    )
    expect(db.table_exists?(:port_transitions)).to eq(true)
    expect(db.schema(:port_transitions).to_h).to include(
      source_name: include(type: :string, allow_null: false, ruby_default: 'proton'),
      detected_at: include(type: :datetime, allow_null: false),
      opnsense_error_at: include(type: :datetime, allow_null: true),
      qbit_error_at: include(type: :datetime, allow_null: true)
    )
    expect(db.table_exists?(:accounts)).to eq(true)
    expect(db.table_exists?(:account_password_hashes)).to eq(true)
    expect(db.table_exists?(:account_oidc_identities)).to eq(true)
    expect(db.table_exists?(:api_keys)).to eq(true)
    expect(db[:settings].count).to eq(0)
  end

  it 'stores one non-null text value per unique setting name' do
    db = Sequel.sqlite
    run_migrations(db)

    expect(db.schema(:settings).to_h).to include(
      id: include(type: :integer, primary_key: true),
      name: include(type: :string, allow_null: false),
      value: include(type: :string, allow_null: false, db_type: 'TEXT')
    )
    expect(db.schema(:settings).map(&:first)).to eq(%i[id name value])
    expect(unique_index?(db, :settings, [:name])).to eq(true)
    db[:settings].insert(name: 'loop_freq', value: '60')

    expect { db[:settings].insert(name: 'loop_freq', value: '120') }
      .to raise_error(Sequel::UniqueConstraintViolation)
    expect { db[:settings].insert(name: nil, value: '60') }.to raise_error(Sequel::NotNullConstraintViolation)
    expect { db[:settings].insert(name: 'required_attempts', value: nil) }
      .to raise_error(Sequel::NotNullConstraintViolation)
  end

  it 'upgrades, rolls back, and reapplies settings without changing unrelated application data' do # rubocop:disable Metrics/BlockLength
    db = Sequel.sqlite
    Sequel.extension :migration
    Sequel::Migrator.run(db, 'db/migrate', target: 9)
    source_id = db[:sources].insert(name: 'opnsense')
    db[:stats].insert(source_id: source_id, current_port: 23_456, last_checked: Time.at(100))
    db[:counters].insert(source_id: source_id, attempt: 3, change: true,
                         pending_apply_port: 23_456, pending_apply_transition_ids: '[1]')
    db[:port_transitions].insert(new_port: 23_456, detected_at: Time.at(100), source_name: 'gluetun')
    db[:notifications].insert(name: 'update_available', info: 'v2.7.0', active: true)
    account_id = db[:accounts].insert(email: 'admin@example.com')
    db[:account_password_hashes].insert(id: account_id, password_hash: 'existing-password-hash')
    db[:account_oidc_identities].insert(account_id: account_id, issuer: 'https://id.example.com', subject: 'admin')
    db[:api_keys].insert(name: 'existing key', token_digest: 'digest', token_prefix: 'qbop_existing',
                         created_at: Time.at(100))
    original_data = db.tables.reject { |table| table == :schema_info }.to_h { |table| [table, db[table].all] }

    run_migrations(db)
    expect(db[:settings].count).to eq(0)
    original_data.each { |table, rows| expect(db[table].all).to eq(rows) }
    db[:settings].insert(name: 'loop_freq', value: '60')
    run_migrations(db)
    expect(db[:settings].get(:value)).to eq('60')

    Sequel::Migrator.run(db, 'db/migrate', target: 9)
    expect(db.table_exists?(:settings)).to be(false)
    original_data.each { |table, rows| expect(db[table].all).to eq(rows) }

    run_migrations(db)
    expect(db[:settings].count).to eq(0)
    original_data.each { |table, rows| expect(db[table].all).to eq(rows) }
  end

  it 'retains stored settings across a database restart' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'qbop.sqlite3')
      db = Sequel.sqlite(path)
      run_migrations(db)
      db[:settings].insert(name: 'port_source', value: 'gluetun')
      db.disconnect

      db = Sequel.sqlite(path)
      expect(db[:settings][name: 'port_source'][:value]).to eq('gluetun')
      db.disconnect
    end
  end

  it 'labels legacy history as Proton and preserves it across migration rollback and reapplication' do
    db = Sequel.sqlite
    Sequel.extension :migration
    Sequel::Migrator.run(db, 'db/migrate', target: 7)
    attributes = {
      previous_port: 12_345, new_port: 23_456, detected_at: Time.at(100),
      opnsense_synced_at: Time.at(200), qbit_error_at: Time.at(300)
    }
    id = db[:port_transitions].insert(attributes)

    run_migrations(db)

    expect(db[:port_transitions][id: id]).to include(attributes.merge(source_name: 'proton'))
    Sequel::Migrator.run(db, 'db/migrate', target: 7)
    expect(db[:port_transitions][id: id]).to include(attributes)
    run_migrations(db)
    expect(db[:port_transitions][id: id][:source_name]).to eq('proton')
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

  it 'adds and rolls back pending apply state without changing existing counters or history' do # rubocop:disable Metrics/BlockLength
    db = Sequel.sqlite
    Sequel.extension :migration
    Sequel::Migrator.run(db, 'db/migrate', target: 8)
    source_id = db[:sources].insert(name: 'opnsense')
    counter_id = db[:counters].insert(source_id: source_id, attempt: 3, change: true)
    transition_id = db[:port_transitions].insert(
      new_port: 23_456, detected_at: Time.at(100), source_name: 'gluetun', opnsense_error_at: Time.at(200)
    )
    counter_before = db[:counters][id: counter_id]
    history_before = db[:port_transitions].all

    run_migrations(db)
    expect(db[:counters][id: counter_id]).to eq(
      counter_before.merge(pending_apply_port: nil, pending_apply_transition_ids: nil)
    )
    db[:counters].where(id: counter_id).update(
      pending_apply_port: 23_456, pending_apply_transition_ids: JSON.generate([transition_id])
    )
    run_migrations(db)
    expect(db[:counters][id: counter_id][:pending_apply_port]).to eq(23_456)
    expect(JSON.parse(db[:counters][id: counter_id][:pending_apply_transition_ids])).to eq([transition_id])

    Sequel::Migrator.run(db, 'db/migrate', target: 8)
    expect(db[:counters][id: counter_id]).to eq(counter_before)
    expect(db[:port_transitions].all).to eq(history_before)
    expect(unique_source_id_index?(db, :counters)).to eq(true)
    run_migrations(db)
    expect(db[:counters][id: counter_id][:pending_apply_port]).to be_nil
    expect(db[:counters][id: counter_id][:pending_apply_transition_ids]).to be_nil
  end

  it 'retains pending apply work across database restart and history deletion' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'qbop.sqlite3')
      db = Sequel.sqlite(path)
      run_migrations(db)
      source_id = db[:sources].insert(name: 'opnsense')
      transition_id = db[:port_transitions].insert(new_port: 23_456, detected_at: Time.at(100))
      db[:counters].insert(source_id: source_id, pending_apply_port: 23_456,
                           pending_apply_transition_ids: JSON.generate([transition_id]))
      db[:port_transitions].delete
      db.disconnect

      db = Sequel.sqlite(path)
      expect(db[:counters][source_id: source_id]).to include(
        pending_apply_port: 23_456, pending_apply_transition_ids: JSON.generate([transition_id])
      )
      db.disconnect
    end
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

  it 'creates issuer-scoped OIDC identities without storing provider tokens' do
    db = Sequel.sqlite
    run_migrations(db)
    account_id = db[:accounts].insert(email: 'admin@example.com')
    schema = db.schema(:account_oidc_identities).to_h

    expect(schema).to include(
      account_id: include(allow_null: false),
      issuer: include(allow_null: false),
      subject: include(allow_null: false)
    )
    expect(schema.keys).not_to include(:access_token, :refresh_token, :id_token)
    expect(unique_index?(db, :account_oidc_identities, [:issuer])).to eq(true)

    db[:account_oidc_identities].insert(
      account_id: account_id, issuer: 'https://id.example.com', subject: 'administrator'
    )
    expect do
      db[:account_oidc_identities].insert(
        account_id: account_id, issuer: 'https://id.example.com', subject: 'replacement'
      )
    end.to raise_error(Sequel::UniqueConstraintViolation)

    db[:accounts].where(id: account_id).delete
    expect(db[:account_oidc_identities].count).to eq(0)
  end

  it 'upgrades, rolls back, and reapplies migration 007 without changing account credentials or API keys' do
    database_path = File.join(Dir.mktmpdir, 'qbop.sqlite3')
    db = Sequel.sqlite(database_path)
    Sequel.extension :migration
    Sequel::Migrator.run(db, 'db/migrate', target: 6)
    account_id = db[:accounts].insert(email: 'admin@example.com')
    db[:account_password_hashes].insert(id: account_id, password_hash: 'existing-password-hash')
    db[:api_keys].insert(
      name: 'existing key', token_digest: 'digest', token_prefix: 'qbop_existing', created_at: Time.now
    )

    Sequel::Migrator.run(db, 'db/migrate', target: 7)
    expect(db.table_exists?(:account_oidc_identities)).to be(true)
    expect(db[:accounts].get(:email)).to eq('admin@example.com')
    expect(db[:account_password_hashes].get(:password_hash)).to eq('existing-password-hash')
    expect(db[:api_keys].get(:token_digest)).to eq('digest')

    Sequel::Migrator.run(db, 'db/migrate', target: 6)
    expect(db.table_exists?(:account_oidc_identities)).to be(false)
    expect(db[:accounts].count).to eq(1)
    expect(db[:api_keys].count).to eq(1)

    Sequel::Migrator.run(db, 'db/migrate', target: 7)
    expect(db.table_exists?(:account_oidc_identities)).to be(true)
    expect(db[:accounts].count).to eq(1)
    expect(db[:api_keys].count).to eq(1)
  end

  it 'allows only one of two concurrent first-link inserts for the same issuer' do # rubocop:disable Metrics/BlockLength
    database_path = File.join(Dir.mktmpdir, 'qbop.sqlite3')
    db = Sequel.sqlite(database_path, max_connections: 2, timeout: 2_000)
    run_migrations(db)
    account_id = db[:accounts].insert(email: 'admin@example.com')
    ready = Queue.new
    start = Queue.new
    results = Queue.new

    threads = %w[subject-one subject-two].map do |subject|
      Thread.new do
        ready << true
        start.pop
        db[:account_oidc_identities].insert(
          account_id: account_id, issuer: 'https://id.example.com', subject: subject
        )
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
    expect(db[:account_oidc_identities].count).to eq(1)
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
