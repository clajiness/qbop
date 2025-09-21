class Notification < Sequel::Model
  def set_update_available(available)
    self.update_available = available
    save
  end
end
