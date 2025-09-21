class Counter < Sequel::Model
  many_to_one :services
end
