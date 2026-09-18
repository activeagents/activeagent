# frozen_string_literal: true

class Post < ApplicationRecord
  belongs_to :user

  # A Rails enum, for the schema-tools tests: declared on the model rather
  # than through an inclusion validator, which is the case SchemaGenerator
  # cannot see and SchemaTools has to read from defined_enums.
  enum :state, { draft: 0, review: 1, live: 2 }, prefix: true

  validates :title, presence: true, length: { maximum: 255 }
  validates :content, presence: true

  scope :published, -> { where(published: true) }
end
