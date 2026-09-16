# frozen_string_literal: true

module ActionAgent
  class AgentVersion < ApplicationRecord
    belongs_to :agent

    validates :version_number, presence: true, uniqueness: { scope: :agent_id }
    validates :configuration_snapshot, presence: true

    # Scopes
    scope :recent, -> { order(version_number: :desc) }
    # Versions cut from the agent's code on deploy, as opposed to edits made
    # in the dashboard.
    scope :releases, -> { where.not(release_digest: [ nil, "" ]) }
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
    # Whether this version was cut from the agent's code (it carries the
    # release digest) rather than from a dashboard edit.
    # @return [Boolean]
    def release?
      release_digest.present?
    end

    def latest?
      agent.latest_version&.id == id
    end

    # Check if this is the initial version
    def initial?
      version_number == 1
    end
  end
end
