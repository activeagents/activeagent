# frozen_string_literal: true

# Copied from solid_agent's install generator template — see AgentContext.
class AgentMemoryEntry < ApplicationRecord
  belongs_to :agent_memory

  validates :content, presence: true

  scope :chronological, -> { order(:created_at) }
  scope :by_category, ->(category) { where(category: category) }
  scope :from_agent, ->(agent_name) { where(source_agent: agent_name) }
end
