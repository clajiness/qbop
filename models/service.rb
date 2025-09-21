class Service < Sequel::Model
  one_to_many :counters
  one_to_many :stats
end
