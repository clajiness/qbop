class Stat < Sequel::Model
  many_to_one :services
end
