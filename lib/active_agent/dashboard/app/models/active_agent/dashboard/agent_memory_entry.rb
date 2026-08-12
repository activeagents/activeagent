# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # One agent-authored summary note in an AgentMemory.
    class AgentMemoryEntry < ApplicationRecord
      belongs_to :agent_memory

      validates :content, presence: true

      scope :chronological, -> { order(:created_at) }
      scope :by_category, ->(category) { where(category: category) }
      scope :from_agent, ->(agent_name) { where(source_agent: agent_name) }
    end
  end
end
