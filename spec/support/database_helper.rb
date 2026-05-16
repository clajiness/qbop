module SpecDatabase
  MODEL_FILES = %w[
    counter
    notification
    source
    stat
  ].freeze

  def self.reset!
    Object.send(:remove_const, :DB) if defined?(DB)
    Object.const_set(:DB, Sequel.sqlite)
    Sequel::Model.db = DB
    Sequel::Model.plugin :update_or_create

    create_tables
    load_models
    set_datasets
  end

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
  end

  def self.load_models
    MODEL_FILES.each { |model| require_relative "../../models/#{model}" }
  end

  def self.set_datasets
    {
      Counter => :counters,
      Notification => :notifications,
      Source => :sources,
      Stat => :stats
    }.each do |model, table|
      model.set_dataset(DB[table])
    end
  end
end
