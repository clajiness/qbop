module SpecDatabase # rubocop:disable Metrics/ModuleLength
  CLEANUP_TABLES = %i[
    api_keys
    account_oidc_identities
    account_password_hashes
    accounts
    port_transitions
    counters
    stats
    notifications
    sources
  ].freeze
  MODEL_FILES = %w[
    api_key
    counter
    notification
    port_transition
    source
    stat
  ].freeze

  def self.reset!
    initialize_database unless @database
    clear_tables
  end

  def self.initialize_database
    Object.send(:remove_const, :DB) if defined?(DB)
    @database = Sequel.sqlite
    Object.const_set(:DB, @database)
    Sequel::Model.db = DB
    Sequel::Model.plugin :update_or_create

    create_tables
    load_models
    set_datasets
  end
  private_class_method :initialize_database

  def self.clear_tables
    DB.transaction do
      CLEANUP_TABLES.each { |table| DB[table].delete }
      DB[:sqlite_sequence].delete if DB.table_exists?(:sqlite_sequence)
    end
  end
  private_class_method :clear_tables

  def self.create_tables # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    DB.create_table(:sources) do
      primary_key :id
      String :name, null: false, unique: true
    end

    DB.create_table(:stats) do
      primary_key :id
      foreign_key :source_id, :sources, null: false
      Integer :current_port, default: 0, null: false
      Integer :same_port, default: 0, null: false
      DateTime :updated_at
      DateTime :last_checked

      index :source_id, unique: true
    end

    DB.create_table(:counters) do
      primary_key :id
      foreign_key :source_id, :sources, null: false
      Integer :attempt, default: 0, null: false
      Boolean :change, default: false, null: false

      index :source_id, unique: true
    end

    DB.create_table(:notifications) do
      primary_key :id
      String :name, null: false, unique: true
      String :info
      Boolean :active, default: false
    end

    DB.create_table(:port_transitions) do
      primary_key :id
      Integer :previous_port
      Integer :new_port, null: false
      DateTime :detected_at, null: false
      DateTime :opnsense_synced_at
      DateTime :qbit_synced_at
      DateTime :opnsense_error_at
      DateTime :qbit_error_at
      Boolean :opnsense_skipped, default: false, null: false
      Boolean :qbit_skipped, default: false, null: false

      index :detected_at
    end

    DB.create_table(:accounts) do
      primary_key :id, type: :Bignum
      String :email, null: false, collate: :nocase
      Integer :single_account_key, null: false, default: 1

      check(single_account_key: 1)
      index :email, unique: true
      index :single_account_key, unique: true
    end

    DB.create_table(:account_password_hashes) do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum, on_delete: :cascade
      String :password_hash, null: false
    end

    DB.create_table(:account_oidc_identities) do
      primary_key :id
      foreign_key :account_id, :accounts, type: :Bignum, null: false, on_delete: :cascade
      String :issuer, null: false
      String :subject, null: false

      index :account_id
      index %i[issuer subject], unique: true
      index :issuer, unique: true
    end

    DB.create_table(:api_keys) do
      primary_key :id
      String :name, null: false
      String :token_digest, null: false
      String :token_prefix, null: false
      DateTime :created_at, null: false
      DateTime :last_used_at

      index :token_digest, unique: true
    end
  end

  def self.load_models
    MODEL_FILES.each { |model| require_relative "../../models/#{model}" }
  end

  def self.set_datasets
    {
      Counter => :counters,
      ApiKey => :api_keys,
      Notification => :notifications,
      PortTransition => :port_transitions,
      Source => :sources,
      Stat => :stats
    }.each do |model, table|
      model.set_dataset(DB[table])
    end
  end
end
