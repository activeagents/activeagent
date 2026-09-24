# frozen_string_literal: true

require "digest"

module ActionAgent
  # Used to store an evaluation an application ran itself, published as the
  # version-1 envelope ActiveAgent::Evals::Publisher sends, in the engine's own
  # evaluation tables, so the Evaluations view shows it the way it shows a run
  # the dashboard executed. It never executes the application's agent.
  #
  # The tenant is the account the ingest key resolved to on a multi-tenant
  # install, and nil on a single-tenant one. The report lands as:
  #   agent      — the tenant's observed agent for the envelope's `source` and
  #                `agent_name`, owned where the tenant's traced agents are
  #                (see #owner)
  #   evaluation — that agent's evaluation for the `suite` and the report's
  #                scope (SCOPE_KEYS in its metadata), named for both
  #   scenarios  — one per reported scenario key, updated to the reported prompt
  #   run        — one complete EvaluationRun per tenant and run_id, with one
  #                EvaluationScenarioResult per scenario and model
  #
  # The run's per-model summary, criterion scores and recommendations are
  # computed from the stored results, not taken from the report. The judge's
  # verdict and label are taken from it.
  #
  # An identical retry returns the stored run. Different content under a run_id
  # already stored raises Conflict. The unique index on the run's tenant and
  # run_id settles concurrent deliveries. A multi-tenant import also holds the
  # tenant's row lock, so one tenant's imports find or create its agent,
  # evaluation and scenarios one at a time.
  class EvaluationReportImport
    class Error < StandardError; end
    class Invalid < Error; end
    class Conflict < Error; end
    class LimitExceeded < Error; end

    MAX_BYTES = 2.megabytes
    MAX_RESULTS = 1000
    MAX_MODELS = 50
    MAX_TEXT = MAX_BYTES
    # The longest evaluation name a string column holds on every supported
    # database (MySQL's VARCHAR(255)).
    MAX_EVALUATION_NAME = 255
    IDENTIFIER_PATTERN = /\A[^[:cntrl:]]{1,200}\z/
    TRACE_PATTERN = /\A[a-zA-Z0-9_-]{1,128}\z/
    SCOPE_PATTERN = %r{\A[\w .:/@-]{1,100}\z}
    STATUSES = %w[passed failed errored].freeze
    # Report metadata that tells one evaluation of a suite from another, in the
    # order it is written into the evaluation's name.
    SCOPE_KEYS = %w[scope environment role].freeze
    # The engine stores at most this much of an answer (ScenarioEvaluationRunner#persist).
    OUTPUT_BYTES = 20_000
    # The largest value each numeric result column holds.
    NUMERIC_LIMITS = {
      "duration_ms" => 2_147_483_647,
      "input_tokens" => 2_147_483_647,
      "output_tokens" => 2_147_483_647,
      "cost" => 999_999
    }.freeze
    # What an observed agent created from a report records as its source.
    AGENT_SOURCE = "evaluation-report"

    # Returns `[run, duplicate]`: the stored EvaluationRun, and whether an
    # earlier identical delivery had already stored it. `account` is the
    # tenant, or nil on a single-tenant install. NUL characters, which
    # PostgreSQL cannot store, are removed from every string first.
    #
    # Raises Invalid for a payload that is not a valid version-1 report,
    # Conflict for different content under a stored run_id or an evaluation
    # the report does not belong to, and LimitExceeded when the owner already
    # holds AgentRegistrar::MAX_OBSERVED_PER_OWNER observed agents.
    def self.call(payload:, account: nil)
      new(payload, account).call
    end

    def initialize(payload, account)
      @payload = without_nul(payload)
      @account = account
    end

    def call
      validate!
      digest = Digest::SHA256.hexdigest(JSON.generate(canonical(@payload)))
      attempts = 0

      begin
        serialized do
          existing = stored_run
          existing ? [ identical!(existing, digest), true ] : [ import(digest), false ]
        end
      rescue ActiveRecord::RecordNotUnique
        # A concurrent delivery committed this run, or an agent, evaluation or
        # scenario this import was creating, first. Reading again sees it.
        existing = stored_run
        return [ identical!(existing, digest), true ] if existing

        attempts += 1
        retry if attempts < 2
        raise
      end
    end

    private

    def report
      @payload["report"]
    end

    def results
      report["results"]
    end

    def metadata
      report["metadata"] || {}
    end

    # The tenant's row lock where there is a tenant, a plain transaction
    # otherwise. A savepoint when the caller already holds a transaction, so
    # a unique-index collision leaves that transaction usable for #call's
    # second read.
    def serialized(&block)
      @account ? @account.with_lock(requires_new: true, &block) : EvaluationRun.transaction(requires_new: true, &block)
    end

    # The value of the run's external_tenant: the tenant's id, or "" with no
    # tenant, because a unique index never treats two NULLs as equal.
    def tenant_key
      @account ? @account.id.to_s : ""
    end

    def stored_run
      EvaluationRun.find_by(external_tenant: tenant_key, external_run_id: @payload["run_id"])
    end

    def identical!(run, digest)
      raise Conflict, "run_id already exists with a different report" unless run.external_report_digest == digest

      run
    end

    def import(digest)
      agent = find_or_create_agent
      evaluation = find_or_initialize_evaluation(agent)
      scenarios = upsert_scenarios(evaluation)
      run = evaluation.evaluation_runs.create!(
        external_tenant: tenant_key,
        external_run_id: @payload["run_id"],
        external_report_digest: digest,
        status: :complete,
        selection: selection,
        scores: recorded_scores,
        samples_evaluated: results.size,
        samples_passed: results.count { |result| result["status"] == "passed" },
        completed_at: Time.current
      )
      results.each { |result| persist(run, scenarios.fetch(result["scenario_key"]), result) }
      run.update!(scores: summarized_scores(run))
      evaluation.touch
      agent.update_columns(last_observed_at: run.completed_at, updated_at: Time.current)
      run
    end

    # --- ownership -------------------------------------------------------------

    # Who a newly observed agent belongs to. Whatever the host's
    # trace_owner_resolver returns for a trace of this tenant, when it has
    # one, so a report's agent lands where the tenant's traced agents do.
    # Otherwise the tenant itself, or nobody on a single-tenant install, as
    # AgentRegistrar decides for a trace.
    #
    # Raises Error when a multi-tenant resolver returns nil, which would place
    # the agent in no tenant's dashboard.
    def owner
      return @owner if defined?(@owner)

      resolver = ActionAgent.trace_owner_resolver
      @owner = resolver ? resolver.call(tenant_trace) : @account
      raise Error, "ActionAgent.trace_owner_resolver returned no owner for the publishing tenant" if @owner.nil? && ActionAgent.multi_tenant?

      @owner
    end

    # An unsaved trace from the publishing application, for the host's
    # trace_owner_resolver: the tenant as its account, and the envelope's
    # source and agent_name as its service and agent class.
    def tenant_trace
      ActionAgent.trace_model.new(service_name: @payload["source"], agent_class: @payload["agent_name"]).tap do |trace|
        trace.account = @account if @account && trace.respond_to?(:account=)
      end
    end

    # The owner's agents. Every agent when the install has no owner to scope
    # to, which is how AgentRegistrar reads a single-tenant dashboard.
    def owner_agents
      owner.nil? && !ActionAgent.multi_tenant? ? Agent.all : Agent.for_owner(owner)
    end

    # --- records ---------------------------------------------------------------

    # Keyed with no action, unlike the per-action agents trace ingest observes:
    # the report evaluates the agent as a whole.
    def find_or_create_agent
      find_agent || create_agent(agent_slug)
    rescue ActiveRecord::RecordNotUnique
      # Another tenant's concurrent first import took the slug.
      find_agent || create_agent("#{slug_base}-#{SecureRandom.hex(3)}")
    end

    def agent_identity
      { service_name: @payload["source"], agent_class_name: @payload["agent_name"], action_name: nil }
    end

    # Narrowed to the tenant, whose owner may also own another tenant's agents.
    def find_agent
      agents = owner_agents.observed_agents
      agents = agents.where(account_id: @account.id) if @account
      agents.find_by(agent_identity)
    end

    # Created inside a savepoint, so a slug collision can be retried without
    # aborting the import's transaction on PostgreSQL.
    def create_agent(slug)
      if owner_agents.observed_agents.count >= AgentRegistrar::MAX_OBSERVED_PER_OWNER
        raise LimitExceeded, "Observed agent limit reached (#{AgentRegistrar::MAX_OBSERVED_PER_OWNER})"
      end

      Agent.transaction(requires_new: true) do
        now = Time.current
        agent = Agent.new(
          agent_identity.merge(
            name: @payload["agent_name"],
            slug: slug,
            status: :observed,
            source: AGENT_SOURCE,
            description: "Evaluation reports published by #{@payload['source']}",
            provider: results.first["provider"],
            model: results.first["model"],
            instructions: "",
            tools: [],
            first_observed_at: now,
            last_observed_at: now
          )
        )
        agent.owner = owner
        agent.account_id = @account.id if @account
        agent.save!
        agent
      end
    end

    # Slugs are checked globally, as AgentRegistrar#observed_slug does, since a
    # host may hold a global unique index on them.
    def agent_slug
      Agent.exists?(slug: slug_base) ? "#{slug_base}-#{SecureRandom.hex(3)}" : slug_base
    end

    # Cut to 200 characters so the suffixed slug fits a VARCHAR(255).
    def slug_base
      @slug_base ||= [ @payload["source"], @payload["agent_name"] ].join("-").parameterize.first(200).presence || "external-agent"
    end

    # An evaluation of this name that no report created, or that another source,
    # suite or scope created, is not this report's to add to.
    def find_or_initialize_evaluation(agent)
      evaluation = agent.evaluations.find_or_initialize_by(name: evaluation_name)
      unless evaluation.new_record?
        return evaluation if evaluation.config["external"] == external_config

        raise Conflict, "The agent already has an evaluation named #{evaluation_name} that this report does not belong to"
      end

      evaluation.assign_attributes(
        judge_kind: judge_label ? "llm" : "rules",
        judge_model: judge_label,
        criteria: [],
        config: { "external" => external_config }
      )
      evaluation
    end

    def external_config
      { "source" => @payload["source"], "suite" => @payload["suite"], "scope" => scope }
    end

    # "orders (eu, support)" for a report whose metadata names a scope and a
    # role; the bare suite for one with no scope.
    def evaluation_name
      values = scope.values
      values.empty? ? @payload["suite"] : "#{@payload['suite']} (#{values.join(', ')})"
    end

    def scope
      SCOPE_KEYS.filter_map { |key| [ key, metadata[key] ] if metadata[key].present? }.to_h
    end

    # The judge that scored the report, or nil when it was scored on rules alone.
    # The framework's pass-rate ranking names itself as the judge of a verdict no
    # model wrote, which is not a judge.
    def judge_label
      label = report["judge"]
      label if label.present? && label != ActiveAgent::Evals::Report::PASS_RATE_JUDGE
    end

    # Adds the scenarios the evaluation lacks and updates each reported one to
    # the prompt and group it ran with. Scenarios the report did not run are left
    # as they are. Returns every scenario of the evaluation by key.
    def upsert_scenarios(evaluation)
      by_key = evaluation.new_record? ? {} : evaluation.scenarios.index_by(&:key)
      next_position = by_key.values.filter_map(&:position).max&.succ || 0

      reported_scenarios.each do |attributes|
        unless by_key.key?(attributes["key"])
          by_key[attributes["key"]] = evaluation.scenarios.build(key: attributes["key"], position: next_position)
          next_position += 1
        end
        by_key[attributes["key"]].assign_attributes(prompt: attributes["prompt"], group: attributes["group"])
      end
      # A new evaluation is valid without criteria only once it has scenarios, so
      # it is saved with them; an existing one saves the scenarios it gained.
      evaluation.save!
      by_key.each_value { |scenario| scenario.save! if scenario.changed? }
      by_key
    end

    def reported_scenarios
      @reported_scenarios ||= results.uniq { |result| result["scenario_key"] }.map do |result|
        { "key" => result["scenario_key"], "prompt" => result["prompt"].presence || result["scenario_key"], "group" => result["group"] }
      end
    end

    def persist(run, scenario, result)
      run.scenario_results.create!(
        scenario: scenario,
        model: result["model"],
        provider: result["provider"],
        status: result["status"],
        score: result["score"],
        scores: result["scores"] || {},
        output: result["answer"].to_s.byteslice(0, OUTPUT_BYTES).to_s.scrub.presence,
        tool_calls: result["tool_calls"] || [],
        duration_ms: result["duration_ms"],
        input_tokens: result["input_tokens"],
        output_tokens: result["output_tokens"],
        cost: result["cost"],
        fault: result["fault"],
        recommendation: result["recommendation"],
        diagnosis: (result["diagnosis"] || {}).merge(
          "_replay_metadata" => result["metadata"] || {},
          "_scenario_snapshot" => {
            "key" => result["scenario_key"], "group" => result["group"], "prompt" => result["prompt"],
            "position" => scenario.position, "expectations" => {}
          }
        ),
        error_message: result["error"]
      )
    end

    # The scenarios and models the run covered, in the shape
    # ScenarioEvaluationRunner records, so EvaluationRun#to_report labels each
    # model the way the report did.
    def selection
      {
        "scenario_keys" => reported_scenarios.map { |scenario| scenario["key"] },
        "models" => results.uniq { |result| result["label"] }.map { |result| result.slice("label", "provider", "model") }
      }
    end

    # What the run keeps from the report itself, which EvaluationRun#to_report
    # reads back when it rebuilds the report.
    def recorded_scores
      {
        "_verdict" => report["verdict"],
        "_selection" => selection,
        "_metadata" => metadata,
        "_judge_label" => judge_label
      }.compact
    end

    # The run's scores in the shape the Evaluations view renders
    # (ScenarioEvaluationRunner#scores_for), summarized from the stored results.
    def summarized_scores(run)
      rebuilt = run.to_report
      rebuilt.criterion_scores.merge(
        "_models" => rebuilt.summary_by_model,
        "_recommendations" => rebuilt.recommendations
      ).merge(recorded_scores)
    end

    # --- validation ------------------------------------------------------------

    def validate!
      object!(@payload, "payload")
      validate_json!(@payload)
      raise Invalid, "version must be 1" unless @payload["version"] == 1

      %w[run_id source suite].each { |key| identifier!(@payload[key], key) }
      string!(@payload["agent_name"], "agent_name", 100, required: true)
      raise Invalid, "agent_name must contain at least two characters" if @payload["agent_name"].strip.length < 2

      object!(report, "report")
      optional_object!(report["metadata"], "report.metadata")
      SCOPE_KEYS.each { |key| scope_value!(metadata[key], "report.metadata.#{key}") }
      if evaluation_name.length > MAX_EVALUATION_NAME
        raise Invalid, "suite and scope name an evaluation longer than #{MAX_EVALUATION_NAME} characters"
      end

      judge_trace_ids!(metadata["judge_trace_ids"])
      string!(report["judge"], "report.judge", 200)
      object!(report["models"], "report.models")
      raise Invalid, "report.models must contain 1-#{MAX_MODELS} models" unless report["models"].size.between?(1, MAX_MODELS)
      unless results.is_a?(Array) && results.size.between?(1, MAX_RESULTS)
        raise Invalid, "report.results must contain 1-#{MAX_RESULTS} results"
      end

      validate_results!
      validate_verdict!
    end

    def validate_results!
      pairs = Set.new
      result_ids = Set.new
      label_specs = {}
      results.each_with_index do |result, index|
        object!(result, "result #{index}")
        %w[scenario_key label provider model].each { |key| string!(result[key], "result.#{key}", 200, required: true) }
        raise Invalid, "result label #{result['label']} is missing from report.models" unless report["models"].key?(result["label"])
        raise Invalid, "duplicate scenario/model result" unless pairs.add?(result.values_at("scenario_key", "label"))

        spec = result.values_at("provider", "model")
        raise Invalid, "result label #{result['label']} names more than one provider/model" if label_specs.fetch(result["label"], spec) != spec

        label_specs[result["label"]] = spec
        raise Invalid, "invalid result status" unless STATUSES.include?(result["status"])
        unless result["fault"].nil? || EvaluationScenarioResult::FAULTS.include?(result["fault"])
          raise Invalid, "unknown fault #{result['fault']}"
        end

        numeric!(result["score"], "result.score", max: 1)
        optional_object!(result["scores"], "result.scores")
        (result["scores"] || {}).each_value { |score| numeric!(score, "criterion score", max: 1) }
        NUMERIC_LIMITS.each { |key, max| numeric!(result[key], "result.#{key}", max: max) }
        %w[prompt answer error recommendation].each { |key| string!(result[key], "result.#{key}", MAX_TEXT) }
        string!(result["group"], "result.group", 200)
        validate_tool_calls!(result["tool_calls"])
        validate_diagnosis!(result["diagnosis"], result["fault"])
        optional_object!(result["metadata"], "result.metadata")
        result_metadata = result["metadata"] || {}
        if result_metadata["result_id"]
          identifier!(result_metadata["result_id"], "result_id")
          raise Invalid, "duplicate result_id" unless result_ids.add?(result_metadata["result_id"])
        end
        trace_id!(result_metadata["trace_id"]) if result_metadata["trace_id"]
        judge_trace_ids!(result_metadata["judge_trace_ids"])
      end
      distinct_specs = label_specs.values.uniq
      raise Invalid, "two model labels name the same provider/model" if distinct_specs.size < label_specs.size
    end

    def validate_tool_calls!(tool_calls)
      return if tool_calls.nil?
      raise Invalid, "result.tool_calls must be an array" unless tool_calls.is_a?(Array)

      tool_calls.each do |call|
        object!(call, "result.tool_calls entry")
        string!(call["name"], "result.tool_calls name", 200, required: true)
      end
    end

    # The diagnosis fields the dashboard reads, in the shapes
    # ActiveAgent::Evals::Diagnosis writes them.
    def validate_diagnosis!(diagnosis, fault)
      return if diagnosis.nil?

      object!(diagnosis, "result.diagnosis")
      raise Invalid, "result.diagnosis.fault must match result.fault" unless diagnosis["fault"].nil? || diagnosis["fault"] == fault

      %w[summary recommendation].each { |key| string!(diagnosis[key], "result.diagnosis.#{key}", MAX_TEXT) }
      optional_object!(diagnosis["evidence"], "result.diagnosis.evidence")
      unavailable = diagnosis.dig("evidence", "unavailable")
      unless unavailable.nil? || (unavailable.is_a?(Array) && unavailable.all?(String))
        raise Invalid, "result.diagnosis.evidence.unavailable must be an array of tool names"
      end

      judge = diagnosis["judge"]
      optional_object!(judge, "result.diagnosis.judge")
      return if judge.nil?

      string!(judge["instruction_change"], "result.diagnosis.judge.instruction_change", MAX_TEXT)
      optional_object!(judge["suggested_tool"], "result.diagnosis.judge.suggested_tool")
      string!(judge.dig("suggested_tool", "name"), "result.diagnosis.judge.suggested_tool.name", 200)
    end

    def validate_verdict!
      verdict = report["verdict"]
      return if verdict.nil?

      object!(verdict, "report.verdict")
      %w[winner judge].each { |key| string!(verdict[key], "report.verdict.#{key}", 200) }
      string!(verdict["rationale"], "report.verdict.rationale", MAX_TEXT)
      return if verdict["winner"].nil? || report["models"].key?(verdict["winner"])

      raise Invalid, "report.verdict.winner is missing from report.models"
    end

    def object!(value, name)
      raise Invalid, "#{name} must be an object" unless value.is_a?(Hash)
    end

    def optional_object!(value, name)
      object!(value, name) unless value.nil?
    end

    def string!(value, name, max, required: false)
      return if value.nil? && !required
      raise Invalid, "#{name} must be a string of at most #{max} characters" unless value.is_a?(String) && value.length <= max
      raise Invalid, "#{name} is required" if required && value.strip.empty?
    end

    def identifier!(value, name)
      raise Invalid, "#{name} must be 1-200 characters without control characters" unless value.is_a?(String) && IDENTIFIER_PATTERN.match?(value)
    end

    def scope_value!(value, name)
      return if value.nil?
      raise Invalid, "#{name} must be 1-100 letters, digits, spaces or . : / @ _ -" unless value.is_a?(String) && SCOPE_PATTERN.match?(value)
    end

    def trace_id!(value)
      raise Invalid, "invalid trace ID" unless value.is_a?(String) && TRACE_PATTERN.match?(value)
    end

    def judge_trace_ids!(value)
      return if value.nil?
      raise Invalid, "judge_trace_ids must be an array of at most 100 IDs" unless value.is_a?(Array) && value.size <= 100

      value.each { |trace| trace_id!(trace) }
    end

    def numeric!(value, name, max:)
      return if value.nil?
      raise Invalid, "#{name} must be a finite number between 0 and #{max}" unless value.is_a?(Numeric) && value.finite? && value.between?(0, max)
    end

    def validate_json!(value, depth = 0)
      raise Invalid, "payload exceeds maximum nesting depth" if depth > 20

      case value
      when Hash
        value.each do |key, child|
          string!(key, "object key", 200, required: true)
          validate_json!(child, depth + 1)
        end
      when Array then value.each { |child| validate_json!(child, depth + 1) }
      when String then raise Invalid, "text is not valid UTF-8" unless value.valid_encoding?
      when Numeric then raise Invalid, "non-finite number" unless value.finite?
      when NilClass, TrueClass, FalseClass then nil
      else raise Invalid, "unsupported JSON value"
      end
    end

    def without_nul(value)
      case value
      when Hash then value.to_h { |key, child| [ without_nul(key), without_nul(child) ] }
      when Array then value.map { |child| without_nul(child) }
      when String then value.delete("\u0000")
      else value
      end
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [ key, canonical(value[key]) ] }
      when Array then value.map { |child| canonical(child) }
      else value
      end
    end
  end
end
