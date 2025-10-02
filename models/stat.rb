class Stat < Sequel::Model
  many_to_one :sources
end
