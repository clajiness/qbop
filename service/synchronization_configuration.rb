require_relative 'settings'
require_relative 'port_source'

module Service
  # Only non-secret startup values needed to interpret synchronization statistics.
  class SynchronizationConfiguration
    KEYS = %i[port_source opnsense_skip qbit_skip loop_freq].freeze
    Snapshot = Data.define(*KEYS) do
      # Pending source/skip metadata keeps its existing public meaning.
      def source_or_skip_changed?(other)
        port_source != other.port_source ||
          opnsense_skip != other.opnsense_skip ||
          qbit_skip != other.qbit_skip
      end
    end

    def initialize
      @mutex = Mutex.new
      @snapshot = nil
    end

    def capture(config)
      snapshot = self.class.from_config(config)
      @mutex.synchronize { @snapshot = snapshot }
    end

    def current(settings)
      @mutex.synchronize { @snapshot } || self.class.resolve(settings)
    end

    def reset
      @mutex.synchronize { @snapshot = nil }
    end

    INSTANCE = new

    def self.capture(config) = INSTANCE.capture(config)
    def self.current(settings) = INSTANCE.current(settings)

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
