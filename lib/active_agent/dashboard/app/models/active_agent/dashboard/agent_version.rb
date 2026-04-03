# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Tracks version history for agent configurations.
    #
    # Each time an agent's configuration changes, a new version is created
    # with a snapshot of the configuration at that point in time.
    #
    # @example Comparing versions
    #   v1 = agent.agent_versions.find_by(version_number: 1)
    #   v2 = agent.agent_versions.find_by(version_number: 2)
    #   changes = v2.diff(v1)
    #
    class AgentVersion < ApplicationRecord
      belongs_to :agent, class_name: "ActiveAgent::Dashboard::Agent"

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
end
