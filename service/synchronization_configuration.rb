require_relative 'settings'
require_relative 'port_source'

module Service
  # Only non-secret startup values needed to interpret synchronization statistics.
  module SynchronizationConfiguration
    KEYS = %i[port_source opnsense_skip qbit_skip loop_freq].freeze
    Snapshot = Data.define(*KEYS) do
      # Pending source/skip metadata keeps its existing public meaning.
      def source_or_skip_changed?(other)
        port_source != other.port_source ||
          opnsense_skip != other.opnsense_skip ||
          qbit_skip != other.qbit_skip
      end
    end

    @mutex = Mutex.new
    @snapshot = nil

    def self.capture(config)
      snapshot = from_config(config)
      @mutex.synchronize { @snapshot = snapshot }
    end

    def self.current(settings)
      @mutex.synchronize { @snapshot } || resolve(settings)
    end

    def self.reset
      @mutex.synchronize { @snapshot = nil }
    end

    def self.resolve(settings)
      from_config(KEYS.to_h { |key| [key, settings.value(key)] })
    end

    def self.from_config(config)
      Snapshot.new(
        port_source: PortSource.name(config).dup.freeze,
        opnsense_skip: config[:opnsense_skip].to_s.downcase == 'true',
        qbit_skip: config[:qbit_skip].to_s.downcase == 'true',
        loop_freq: config.fetch(:loop_freq)
      )
    end
  end
end
