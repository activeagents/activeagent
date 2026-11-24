class Issue < ApplicationRecord
  STATUSES   = %w[open in_progress resolved closed].freeze
  PRIORITIES = %w[low medium high urgent].freeze
  COMPONENTS = %w[checkout billing auth search notifications api].freeze

  belongs_to :reporter, class_name: "User"
  belongs_to :assignee, class_name: "User", optional: true
  belongs_to :duplicate_of, class_name: "Issue", optional: true
  has_many :duplicates, class_name: "Issue", foreign_key: :duplicate_of_id, dependent: :nullify
  has_many :comments, -> { order(:created_at) }, dependent: :destroy

  validates :title, presence: true, length: { maximum: 140 }
  validates :status, inclusion: { in: STATUSES }
  validates :priority, inclusion: { in: PRIORITIES }
  validates :component, inclusion: { in: COMPONENTS }, allow_blank: true
  validate :not_a_duplicate_of_itself

  before_save :stamp_closed_at

  scope :active, -> { where(status: %w[open in_progress]) }
  scope :by_urgency, -> {
    order(Arel.sql("CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END"), updated_at: :desc)
  }
  scope :matching, ->(query) {
    next all if query.blank?

    pattern = "%#{sanitize_sql_like(query.strip)}%"
    where("title LIKE :q OR body LIKE :q", q: pattern)
  }

  def reference = "##{id}"

  def done? = status.in?(%w[resolved closed])

  private

  def stamp_closed_at
    return unless status_changed?

    self.closed_at = done? ? (closed_at || Time.current) : nil
  end

  def not_a_duplicate_of_itself
    errors.add(:duplicate_of, "can't be the issue itself") if duplicate_of_id.present? && duplicate_of_id == id
  end
end
