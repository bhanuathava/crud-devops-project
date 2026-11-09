class Task < ApplicationRecord
  validates :title, presence: true
  validates :completed, inclusion: { in: [ true, false ] }

  # Same JSON shape as the original Node.js app: { id, title, completed }
  def as_json(_options = nil)
    { id: id, title: title, completed: completed }
  end
end
