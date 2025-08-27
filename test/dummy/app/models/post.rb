# frozen_string_literal: true

class Post < ApplicationRecord
  belongs_to :user
  
  validates :title, presence: true, length: {maximum: 255}
  validates :content, presence: true
  
  scope :published, -> { where(published: true) }
end