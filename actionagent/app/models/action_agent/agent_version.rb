# frozen_string_literal: true

module ActionAgent
  class AgentVersion < ApplicationRecord
    belongs_to :agent

    validates :version_number, presence: true, uniqueness: { scope: :agent_id }
    validates :configuration_snapshot, presence: true

    # Scopes
    scope :recent, -> { order(version_number: :desc) }
    scope :by_version, ->(num) { where(version_number: num) }

    # Compare two versions
    def diff(other_version)
      return {} unless other_version

      changes = {}
      configuration_snapshot.each do |key, value|
        other_value = other_version.configuration_snapshot[key]
        if value != other_value
          changes[key] = { from: other_value, to: value }
        end
      end
      changes
    end

    # Get previous version
    def previous
      agent.agent_versions.where("version_number < ?", version_number).order(version_number: :desc).first
    end

    # Get next version
    def next_version
      agent.agent_versions.where("version_number > ?", version_number).order(version_number: :asc).first
    end

    # Check if this is the latest version
    def latest?
      agent.latest_version&.id == id
    end

    # Check if this is the initial version
    def initial?
      version_number == 1
    end
  end
end
