require 'bundler/setup'
Bundler.require(:default)

RSpec.describe 'database migrations' do # rubocop:disable Metrics/BlockLength
  def run_migrations(db)
    Sequel.extension :migration
    Sequel::Migrator.run(db, 'db/migrate')
  end

  def unique_source_id_index?(db, table)
    db.indexes(table).any? do |_name, index|
      index[:unique] && index[:columns] == [:source_id]
    end
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
