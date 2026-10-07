# frozen_string_literal: true

module ActionAgent
  # A bounded, server-built brief for one persisted fix card. Request bodies
  # choose an existing card and a subset of its scope; they cannot inject a
  # different prompt, agent, scenario or model into the automatic fix loop.
  class EvaluationFix
    class Invalid < StandardError; end
    attr_reader :run, :item

    def initialize(run, requested)
      @run = run
      raise Invalid, "Only completed scenario runs have implementable fixes" unless run.complete? && run.evaluation.scenario_suite?
      requested = requested.to_h.deep_stringify_keys
      original = EvaluationSerializer.fix_items(run).find do |candidate|
        candidate = candidate.deep_stringify_keys
        candidate["kind"] == requested["kind"] &&
          (requested["kind"] == "instruction" ? candidate["quote"] == requested["quote"] : candidate["fault"] == requested["fault"])
      end
      raise Invalid, "This fix card no longer exists on the selected run" unless original && %w[fault instruction].include?(requested["kind"])

      @item = original.deep_stringify_keys.slice("kind", "fault", "quote", "recommendation", "scenario_keys", "models")
      keys = Array(requested["scenario_keys"])
      allowed_models = Array(@item["models"]).presence || model_labels
      models = Array(requested["models"]).presence || allowed_models
      unless keys.any? && (keys - Array(@item["scenario_keys"])).empty? && models.any? && (models - allowed_models).empty?
        raise Invalid, "Choose scenarios and models from this fix card"
      end
      @item.merge!("scenario_keys" => keys.uniq, "models" => models.uniq)
      @item["scenarios"] = run.scenario_results.includes(:scenario).filter_map do |result|
        snapshot = result.evaluated_scenario.slice("key", "prompt", "expectations", "notes", "enabled")
        snapshot if keys.include?(snapshot["key"])
      end.uniq
      self.class.check_scenarios!(run.evaluation, @item)
    end

    def self.check_scenarios!(evaluation, item)
      Array(item["scenarios"]).each do |snapshot|
        current = evaluation.scenarios.find_by(key: snapshot.fetch("key"))
        unless current&.enabled? && current.as_json_summary.stringify_keys.slice(*snapshot.keys) == snapshot
          raise Invalid, "The selected scenarios changed since this run. Run the evaluation again before implementing a fix."
        end
      end
    end

    def model_labels
      run.scenario_results.map { |result| [ result.provider, result.model ].compact_blank.join("/") }.uniq
    end

    # How much of each piece of evidence the brief quotes, at full size. A
    # card with many scenarios and models, or a retry, shrinks them all
    # (see #prompt) rather than refusing the card.
    EXCERPTS = { prompt: 1000, expectations: 1000, diagnosis: 1200, answer: 1000,
      previous_result: 1500, previous_diff: 5000, previous_results: 3000 }.freeze
    SCALES = [ 1, 0.5, 0.25, 0.1 ].freeze

    def prompt(previous: nil)
      SCALES.each do |scale|
        text = brief(previous, EXCERPTS.transform_values { |size| (size * scale).to_i })
        return text if text.length <= CodeSession::MAX_PROMPT_CHARACTERS
      end
      raise Invalid, "This fix has too much context for one session; run the evaluation on fewer scenarios or models"
    end

    private

    def brief(previous, limit)
      agent = run.evaluation.agent
      name = agent.agent_class_name.presence || agent.telemetry_agent_class
      path = name.to_s.underscore
      lines = [ "# Implement one evaluation fix", "", "Agent: #{name}", "Evaluation: #{run.evaluation.name} · run #{run.id}",
        "", "## What to fix", item["fault"], item["recommendation"], item["quote"],
        "", "## Where to look", "- app/agents/#{path}.rb and its tools.",
        "- app/views/agents/#{path.delete_suffix('_agent')}/ and app/views/#{path}/ for instructions and prompts.",
        "- Follow the checkout's own instructions and locate the source of a synced agent before editing.",
        "", "## Failing scenarios" ]
      run.scenario_results.includes(:scenario).each do |result|
        scenario = result.evaluated_scenario
        next unless item["scenario_keys"].include?(scenario["key"])
        label = [ result.provider, result.model ].compact_blank.join("/")
        next unless item["models"].include?(label) || item["models"].include?(result.model)
        lines += [ "", "### #{scenario['key']} · #{label}",
          "Prompt: #{scenario['prompt'].to_s.truncate(limit[:prompt])}", "Expectations: #{scenario['expectations'].to_json.truncate(limit[:expectations])}",
          "Before: #{result.status} · score #{result.score} · fault #{result.fault}",
          "Diagnosis: #{result.diagnosis.to_json.truncate(limit[:diagnosis])}", "Answer: #{result.output.to_s.truncate(limit[:answer])}" ]
      end
      if previous
        lines += [ "", "## Previous attempt", previous.result.to_s.truncate(limit[:previous_result]),
          "Previous diff:", previous.diff.to_s.truncate(limit[:previous_diff]),
          "Verification results: #{EvaluationFixComparison.new(previous).rows.to_json.truncate(limit[:previous_results])}" ]
      end
      lines += [ "", "## Verify", "Change the agent, not the scenarios or their expectations.",
        "Run the relevant checkout tests. Do not commit or push.",
        "The dashboard will re-run these exact scenarios and models against this sandbox when you finish.",
        "Do not call dashboard URLs or dashboard MCP tools from this sandbox.",
        "Never read or copy the sandbox's Claude configuration or credentials.",
        "Summarize the change and any remaining limitations." ]
      lines.compact.join("\n")
    end
  end
end
