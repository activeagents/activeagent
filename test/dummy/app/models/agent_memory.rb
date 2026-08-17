# frozen_string_literal: true

# Copied from solid_agent's install generator template — see AgentContext.
# Kept loadable when the resolved solid_agent predates HasMemory, so the
# default bundle can still boot the dummy app.
class AgentMemory < ApplicationRecord
  DEFAULT_SCOPE = defined?(SolidAgent::HasMemory) ? SolidAgent::HasMemory::DEFAULT_SCOPE : "default"

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

  def forget(entry_id)
    entries.find(entry_id).destroy!
  end

  def summary_list
    entries.order(:created_at).pluck(:content)
  end

  def to_prompt
    notes = entries.order(:created_at).map do |entry|
      source = entry.source_agent.present? ? " (#{entry.source_agent})" : ""
      "- #{entry.content}#{source}"
    end
    return "" if notes.empty?

    "Memory notes for this subject:\n#{notes.join("\n")}"
  end
end
