module Service
  # Plaintext is available only through value; diagnostic representations redact sensitive settings.
  SettingsResolution = Data.define(:value, :source, :environment_name, :environment_override, :secret) do
    def environment_override? = environment_override
    def secret? = secret

    def to_h(&block)
      attributes = { value: secret? ? '***' : value, source: source, environment_name: environment_name,
                     environment_override: environment_override }
      attributes[:secret] = true if secret?
      block ? attributes.to_h(&block) : attributes
    end

    def inspect
      "#<#{self.class.name} #{to_h.inspect}>"
    end
    alias_method :to_s, :inspect

    def pretty_print(printer)
      printer.text(inspect)
    end
  end
end
