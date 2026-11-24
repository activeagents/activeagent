class User < ApplicationRecord
  has_many :reported_issues, class_name: "Issue", foreign_key: :reporter_id, dependent: :restrict_with_error
  has_many :assigned_issues, class_name: "Issue", foreign_key: :assignee_id, dependent: :nullify
  has_many :comments, foreign_key: :author_id, dependent: :destroy

  validates :name, presence: true
  validates :handle, presence: true, uniqueness: true

  def initials
    name.split.map(&:first).first(2).join.upcase
  end
end
