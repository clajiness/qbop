module Service
  # Safe editor metadata: sensitive values are always nil, and presence never reads ciphertext.
  SettingsMetadata = Data.define(:key, :label, :value, :source, :environment_name, :environment_override,
                                 :secret, :database_value_present, :default_value, :input_type,
                                 :choices, :minimum, :maximum) do
    def environment_override? = environment_override
    def secret? = secret
    def database_value_present? = database_value_present
    def default? = source == :default

    def unset?
      return !environment_override? && !database_value_present? if secret?

      value.nil? || value.to_s.strip.empty?
    end
  end
end
