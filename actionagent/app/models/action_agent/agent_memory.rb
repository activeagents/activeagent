# frozen_string_literal: true

module ActionAgent
  # Agent-curated long-term memory for a subject record (solid_agent
  # HasMemory contract). On this platform the memorable is usually the
  # dashboard Agent record; agents write/read it through the save_memory /
  # recall_memory tools during generation runs.
  #
  # Memory is scoped to (memorable, scope) — not to an agent class — so any
  # agent operating on the same subject shares it, making it a handoff
  # channel between agents. Entry source_agent records who wrote each note.
  class AgentMemory < ApplicationRecord
    DEFAULT_SCOPE = "default"

    belongs_to :memorable, polymorphic: true, optional: true
    has_many :entries, class_name: "AgentMemoryEntry", dependent: :destroy

    validates :scope, presence: true

    def self.for(memorable, scope: DEFAULT_SCOPE)
      find_or_create_by!(memorable: memorable, scope: scope.to_s)
    end

    def remember(content, source_agent: nil, category: nil)
      entries.create!(content: content, source_agent: source_agent, category: category)
    end

    def recall(limit: 20, category: nil)
      scope = entries.order(created_at: :desc)
      scope = scope.where(category: category) if category.present?
      scope.limit(limit || 20).to_a
    end

    def summary_list
      entries.order(:created_at).pluck(:content)
    end

    # Formatted block suitable for injecting into another agent's
    # instructions when handing a subject off.
    def to_prompt
      notes = entries.order(:created_at).map do |entry|
        source = entry.source_agent.present? ? " (#{entry.source_agent})" : ""
        "- #{entry.content}#{source}"
      end
      return "" if notes.empty?

      "Memory notes for this subject:\n#{notes.join("\n")}"
    end
  end
end
