# frozen_string_literal: true

module ActionAgent
  # Cuts a version of every dashboard agent that mirrors a host class, from
  # that class's release digest — what a deploy runs so the dashboard's
  # versions line up with the code that shipped.
  #
  # The host owns the mirror: whatever syncs its ActiveAgent classes into
  # Agent records sets `agent_class_name`, and this reads it back. A record
  # whose class no longer resolves, or whose class predates
  # ActiveAgent::Release, is reported and skipped rather than failed.
  #
  # Idempotent: a redeploy of an unchanged agent cuts nothing, so running it
  # on every deploy is the intended use (`rake action_agent:agents:release`).
  class AgentRelease
    Row = Struct.new(:agent, :version, :cut, :skipped, keyword_init: true)
    Result = Struct.new(:rows, :revision, keyword_init: true) do
      def cut = rows.select(&:cut)
      def skipped = rows.select(&:skipped)
    end

    # @param revision [String, nil] the deploy (git SHA, release label);
    #   ActiveAgent::Release.revision when nil
    # @param agents [ActiveRecord::Relation] the records to release; every
    #   record naming a host class by default
    # @param released_by [String, nil] recorded on each version cut
    def self.call(revision: nil, agents: nil, released_by: nil)
      new(revision: revision, agents: agents, released_by: released_by).call
    end

    def initialize(revision: nil, agents: nil, released_by: nil)
      @revision = revision.presence || ActiveAgent::Release.revision
      @agents = agents || Agent.where.not(agent_class_name: [ nil, "" ])
      @released_by = released_by
    end

    # @return [Result]
    def call
      rows = @agents.order(:name).map { |agent| release(agent) }
      Result.new(rows: rows, revision: @revision)
    end

    private

    def release(agent)
      klass = agent.agent_class_name.to_s.safe_constantize
      unless klass.respond_to?(:release_digest)
        return Row.new(agent: agent, version: nil, cut: false, skipped: "#{agent.agent_class_name} does not resolve to a releasable class")
      end

      before = agent.latest_version&.id
      version = agent.record_release!(
        digest: klass.release_digest,
        manifest: klass.release_manifest,
        revision: @revision,
        released_by: @released_by
      )
      Row.new(agent: agent, version: version, cut: version.id != before, skipped: nil)
    end
  end
end
