# frozen_string_literal: true

module ActionAgent
  # Where an evaluation stands against the agent as it is now, so a pass
  # rate on the Evaluations page describes the current agent rather than
  # pooling every suite's last run, however old the code it scored.
  #
  # The evaluation's headline run is its newest complete run; a newer run
  # still pending or failed shows beside it, never in its place. Its
  # standing is one of:
  #
  #   current    — the headline run scored the agent's current version
  #   stale      — it scored an earlier version, or a release the dashboard
  #                has not matched to the agent's current release
  #   unrecorded — the run recorded no version and the agent has no release
  #                versions at all, so nothing says which code it scored
  #   archived   — the evaluation is archived (Evaluation#archive!)
  #   none       — no complete run
  #
  # Only edits that change how a run goes count as a new version: what the
  # model is given (the instructions, the action prompts, the tools, the MCP
  # servers, the model config and the response format), and the tools whose
  # calls wait for a person's approval, which pause a replay. A dashboard
  # edit to the agent's appearance cuts an AgentVersion like any other edit,
  # but the run before it scored the same agent and stays current.
  class EvaluationStanding
    STANDINGS = %w[current stale unrecorded archived none].freeze
    VERSION_STATES = %w[current earlier unrecorded].freeze
    # The configuration snapshot keys the model is given.
    MODEL_FACING = %w[instructions action_prompts tools mcp_servers model_config response_format].freeze
    # The configuration snapshot keys that change how a run goes.
    SCORED = (MODEL_FACING + %w[approval_required_tools]).freeze

    # Gives every evaluation its standing with one query per table rather
    # than one per evaluation: the agents' latest versions and whether each
    # has a release are read for the page at once.
    def self.preload(evaluations)
      evaluations = Array(evaluations)
      agent_ids = evaluations.filter_map(&:agent_id).uniq
      return if agent_ids.empty?

      newest = AgentVersion.where(agent_id: agent_ids).group(:agent_id).maximum(:version_number)
      latest = AgentVersion.where(agent_id: agent_ids).where(version_number: newest.values.uniq)
        .select { |version| newest[version.agent_id] == version.version_number }.index_by(&:agent_id)
      releases = AgentVersion.releases.where(agent_id: agent_ids).distinct.pluck(:agent_id).to_set

      evaluations.each do |evaluation|
        evaluation.standing_info = new(evaluation, latest_version: latest[evaluation.agent_id], has_releases: releases.include?(evaluation.agent_id))
      end
    end

    attr_reader :evaluation

    # @param headline_run [EvaluationRun, nil] the headline run when the
    #   caller already holds it (AgentScorecard selects one per evaluation)
    def initialize(evaluation, latest_version: :unknown, has_releases: :unknown, headline_run: :unknown)
      @evaluation = evaluation
      @latest_version = latest_version
      @has_releases = has_releases
      @headline_run = headline_run
    end

    def headline_run
      return @headline_run unless @headline_run == :unknown

      @headline_run = evaluation.headline_run
    end

    # The same standing read against +run+ as the headline run.
    def with_headline(run)
      self.class.new(evaluation, latest_version: latest_version, has_releases: has_releases?, headline_run: run)
    end

    def standing
      return "archived" if evaluation.archived?
      return "none" unless headline_run

      case version_state(headline_run)
      when "current" then "current"
      when "unrecorded" then has_releases? ? "stale" : "unrecorded"
      else "stale"
      end
    end

    # Whether +run+ scored the agent's current version: "current",
    # "earlier", or "unrecorded" when it recorded no version.
    def version_state(run)
      version = run&.agent_version
      return "unrecorded" unless version

      # The agent's last recorded deploy is the truth about the code that
      # runs: a release version matching it is current whatever the
      # dashboard edited since, and one that does not is earlier even when
      # it was recorded last (a report of an older deploy published late).
      if version.release? && (deployed = evaluation.agent&.release_digest.presence)
        return deployed == version.release_digest ? "current" : "earlier"
      end

      latest = latest_version
      return "current" if latest.nil? || latest.id == version.id
      return "current" if scored_configuration(version) == scored_configuration(latest)

      "earlier"
    end

    # Passes per model label of the headline run, `{ label => { passed, total } }`,
    # from its recorded summaries; empty without them.
    def per_model
      run = headline_run
      return {} unless run

      summaries = run.scores.is_a?(Hash) ? (run.scores["_models"].presence || run.scores["_cohorts"]) : nil
      return {} unless summaries.is_a?(Hash)

      summaries.filter_map do |label, stats|
        next unless stats.is_a?(Hash)

        total = (stats["scenarios"] || stats["samples"]).to_i
        [ label, { passed: stats["passed"].to_i, total: total } ]
      end.to_h
    end

    # What the index and the scorecards pool: a current or unrecorded
    # headline run; a stale or archived evaluation is left out and said so.
    def counted?
      %w[current unrecorded].include?(standing)
    end

    private

    def latest_version
      return @latest_version unless @latest_version == :unknown

      @latest_version = evaluation.agent&.latest_version
    end

    def has_releases?
      return @has_releases unless @has_releases == :unknown

      @has_releases = evaluation.agent&.agent_versions&.releases&.exists? || false
    end

    # A snapshot taken before an agent had an approval list reads as an empty
    # one, so the list's arrival alone cuts no new version.
    def scored_configuration(version)
      snapshot = version.configuration_snapshot.to_h.stringify_keys
      configuration = SCORED.to_h { |key| [ key, snapshot[key] ] }
      configuration["approval_required_tools"] = Array(configuration["approval_required_tools"])
      configuration
    end
  end
end
