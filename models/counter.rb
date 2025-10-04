class Counter < Sequel::Model # rubocop:disable Style/Documentation
  many_to_one :sources
end
