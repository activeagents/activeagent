# frozen_string_literal: true

class User < ApplicationRecord
  has_many :posts
  has_one :profile

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true, length: { minimum: 2, maximum: 100 }
  validates :age, numericality: { greater_than_or_equal_to: 18, less_than: 120 }
  validates :role, inclusion: { in: [ "admin", "moderator", "user" ] }
end
