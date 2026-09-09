# frozen_string_literal: true

module ActionAgent
  # Compiles what a coding agent needs to know before it touches an agent's
  # code: what the agent's evaluations say it cannot do yet, why, what would
  # fix it, how it behaves in production, and what the sandbox it is about to
  # work in will and will not let it do.
  #
  # Every judgement here is already made elsewhere and is only translated:
  #
  #   ActiveAgent::Evals::Report#fix_items    what to fix, per fault, with the
  #                                           tools and MCP server involved
  #   ActiveAgent::Evals::Report#summary_by_model / #verdict
  #                                           how each candidate model did
  #   EvaluationScenarioResult                the scenarios that failed, the
  #                                           fault each carries, the tools called
  #   EvaluationToolResolver (through the report's tool_resolver)
  #                                           whether the agent already has the
  #                                           server a missing tool belongs to
  #   MetricsReport                           the production signal: volume,
  #                                           error rate, latency, cost
  #   CodeAgentCatalog                        what the coding agent itself needs
  #
  # Nothing here reads a credential value. Where a credential matters, only
  # the environment variable NAME appears, and only to say whether it is
  # present, so the brief is safe to persist, render and mount read-only in
  # a container.
  class CodeSessionBrief
    VERSION = 1

    MAX_NEEDS = 12
    MAX_LIMITATIONS = 12
    MAX_FAILING_SCENARIOS = 20
    INSTRUCTIONS_EXCERPT = 600

    # Above this, production reliability is a limitation worth telling the
    # coding agent about rather than a number it can ignore.
    ERROR_RATE_LIMIT = 5.0
    P95_LIMIT_MS = 10_000

    # Faults whose fix is a capability the agent does not have, so they read
    # as something it needs; everything else is a quality problem.
    CAPABILITY_FAULTS = %w[expected_tool_not_called missing_capability].freeze

    def self.call(...) = new(...).to_h

    # Renders a stored brief hash back to markdown, so a session that was
    # compiled hours ago writes the same BRIEF.md its dashboard shows.
    def self.markdown_for(brief, session: nil)
      Markdown.new(brief.to_h.deep_stringify_keys, session: session).to_s
    end

    # @param agent [ActionAgent::Agent]
    # @param evaluation_run [ActionAgent::EvaluationRun, nil] the run to seed
    #   from; the agent's most recent complete scenario run when omitted
    # @param tool [String] a CodeAgentCatalog key
    # @param backend [CodeSessionOrchestrator, String, nil] for the sandbox's
    #   own constraints
    # @param owner [Object, nil] whose credentials and traces to read
    def initialize(agent:, tool:, evaluation_run: nil, backend: nil, owner: nil, traces: nil,
                   network_mode: "restricted", github_access: "none", repository: nil, task: nil)
      @agent = agent
      @tool = tool.to_s
      @evaluation_run = evaluation_run || latest_run
      @backend = backend
      @owner = owner
      @traces = traces
      @network_mode = network_mode.to_s
      @github_access = github_access.to_s
      @repository = repository.presence
      @task = task.presence
    end

    attr_reader :agent, :evaluation_run

    def to_h
      {
        "version" => VERSION,
        "generated_at" => Time.current.iso8601,
        "agent" => agent_section,
        "evaluation" => evaluation_section,
        "needs" => needs,
        "limitations" => limitations,
        "failing_scenarios" => failing_scenarios,
        "metrics" => metrics_section,
        "code_agent" => code_agent_section,
        "sandbox" => sandbox_section,
        "task" => task
      }
    end

    def to_markdown
      Markdown.new(to_h, session: nil).to_s
    end

    # What the coding agent is asked to do when the operator wrote nothing.
    # Deliberately concrete about scope and about saying what it could not
    # do: a coding agent that silently gives up is worse than one that
    # reports a blocked need.
    # Memoized because push_instruction names a fresh branch each time it is
    # built: without this, #to_h and #to_markdown — and the brief the
    # controller persists next to session.task — would each tell the coding
    # agent to commit on a different branch.
    def task
      @task ||= <<~TASK.strip
        Work in /workspace/repo. Address the needs in this brief: add the tools or MCP servers
        the evaluations say are missing, change the agent's instructions where they say so, and
        cover each fix with a test. Do not change unrelated code.

        Finish by summarizing what you changed and what still cannot be done with the tools
        available here.#{" "}
        #{push_instruction}
      TASK
    end

    private

    def push_instruction
      return "Do not commit: this session has no write access to the repository." unless @github_access == "write"

      "Commit on a branch named code-session/#{SecureRandom.hex(4)} and open a pull request."
    end

    # --- sources ----------------------------------------------------------

    # The newest run worth seeding from: a complete scenario run first,
    # because only those carry per-scenario faults; a complete sampling run
    # otherwise, which contributes scores but no needs.
    def latest_run
      return nil if @agent.nil?

      runs = EvaluationRun.joins(:evaluation)
        .where(action_agent_evaluations_table => { agent_id: @agent.id })
        .where(status: EvaluationRun.statuses[:complete])
        .order(created_at: :desc)
        .limit(20)

      runs.find { |run| run.scenario_results.exists? } || runs.first
    rescue ActiveRecord::StatementInvalid
      # An install without the evaluation tables still gets a brief.
      nil
    end

    def action_agent_evaluations_table
      Evaluation.table_name.to_sym
    end

    def scenario_run?
      @scenario_run ||= evaluation_run.present? && evaluation_run.scenario_results.exists?
    rescue ActiveRecord::StatementInvalid
      false
    end

    def report
      return @report if defined?(@report)

      @report = scenario_run? ? evaluation_run.to_report : nil
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] code session brief could not build a report: #{e.message}")
      @report = nil
    end

    def fix_items
      @fix_items ||= Array(report&.fix_items)
    end

    def faulted_results
      @faulted_results ||= begin
        return [] unless scenario_run?

        evaluation_run.scenario_results.includes(:scenario).where.not(fault: nil).order(:id).to_a
      rescue ActiveRecord::StatementInvalid
        []
      end
    end

    # --- sections ---------------------------------------------------------

    def agent_section
      return nil if @agent.nil?

      {
        "id" => @agent.id,
        "name" => @agent.name,
        "slug" => @agent.slug,
        "provider" => @agent.provider,
        "model" => @agent.model,
        "instructions_excerpt" => @agent.instructions.to_s.strip[0, INSTRUCTIONS_EXCERPT].presence,
        "tools" => Array(@agent.tools).map(&:to_s),
        "mcp_servers" => mcp_server_names
      }
    end

    def mcp_server_names
      servers = @agent.mcp_servers
      return servers.keys.map(&:to_s) if servers.is_a?(Hash)

      Array(servers).filter_map do |entry|
        next entry.to_s if entry.is_a?(String) || entry.is_a?(Symbol)
        next unless entry.respond_to?(:key?)

        (entry["key"] || entry[:key] || entry["name"] || entry[:name]).to_s.presence
      end
    end

    def evaluation_section
      return nil if evaluation_run.nil?

      evaluation = evaluation_run.evaluation
      summary = report&.summary_by_model || {}
      totals = summary.values

      {
        "id" => evaluation&.id,
        "name" => evaluation&.name,
        "run_id" => evaluation_run.id,
        "kind" => scenario_run? ? "scenario" : "sampled",
        "completed_at" => evaluation_run.completed_at&.iso8601,
        "status" => evaluation_run.status,
        "scenarios" => totals.sum { |stats| stats["scenarios"].to_i },
        "passed" => totals.sum { |stats| stats["passed"].to_i },
        "pass_rate" => pass_rate(totals),
        "average_score" => evaluation_run.average_score,
        "models" => summary,
        "verdict" => report&.verdict
      }
    end

    def pass_rate(totals)
      scenarios = totals.sum { |stats| stats["scenarios"].to_i }
      return nil if scenarios.zero?

      (totals.sum { |stats| stats["passed"].to_i } * 100.0 / scenarios).round(1)
    end

    # Needs are the capability gaps: a tool the agent could not call, the MCP
    # server that serves it, an instruction the judge would change, and the
    # credentials the run itself was short of.
    def needs
      items = fix_items.filter_map { |item| need_from(item) }
      items += rate_limit_need
      items.first(MAX_NEEDS)
    end

    def need_from(item)
      kind = item["kind"].to_s
      tools = Array(item["tools"])
      server = item["server"]

      if kind == "instruction"
        # The sentence the judge wants added lives in "quote": the fault card
        # built from the same result already carries the recommendation, so
        # Report#instruction_fix_items leaves that field nil on purpose.
        return {
          "kind" => "instruction",
          "title" => "Change the agent's instructions",
          "detail" => item["quote"].presence || item["recommendation"].to_s,
          "tools" => [],
          "server" => nil,
          "evidence" => evidence_for(item),
          "action" => action_for(item)
        }
      end

      return nil unless CAPABILITY_FAULTS.include?(item["fault"].to_s)
      return nil if tools.empty? && item["recommendation"].blank?

      names = tools.map { |tool| tool["name"].to_s }
      {
        "kind" => server ? "mcp_server" : "tool",
        "title" => need_title(item, names, server),
        "detail" => [ item["recommendation"], item["note"] ].compact_blank.join(" "),
        "tools" => names,
        "server" => server,
        "evidence" => evidence_for(item),
        "action" => action_for(item)
      }
    end

    def need_title(item, names, server)
      listed = names.first(3).join(", ")
      listed = "#{listed} and #{names.size - 3} more" if names.size > 3

      if server
        status = server["status"].to_s == "enabled" ? "already enabled" : server["status"].presence || "unknown"
        "Give the agent #{listed} from #{server["name"]} (#{status})"
      elsif names.any?
        "Give the agent #{listed}"
      else
        "Missing capability: #{item["fault"].to_s.humanize.downcase}"
      end
    end

    def evidence_for(item)
      {
        "fault" => item["fault"],
        "count" => item["count"],
        "scenario_keys" => Array(item["scenario_keys"]).first(8),
        "models" => Array(item["models"])
      }.compact
    end

    def action_for(item)
      action = item["action"]
      return nil if action.blank?

      { "label" => action["label"], "hint" => action["hint"], "path" => action["path"] }.compact
    end

    def rate_limit_need
      rate_limited = metrics_section&.dig("errors_by_type", "429 rate limit").to_i
      return [] unless rate_limited.positive?

      [ {
        "kind" => "credential",
        "title" => "Provider rate limits are being hit",
        "detail" => "#{rate_limited} rate-limited requests in the last window. A higher-tier key, " \
                    "a second provider, or backoff in the agent would clear them.",
        "tools" => [],
        "server" => nil,
        "evidence" => { "fault" => "429 rate limit", "count" => rate_limited },
        "action" => nil
      } ]
    end

    # Limitations are what the agent gets wrong rather than what it lacks:
    # failing quality checks, tools that error, and the production signal.
    def limitations
      items = fix_items.filter_map { |item| limitation_from(item) }
      items += metric_limitations
      items.first(MAX_LIMITATIONS)
    end

    def limitation_from(item)
      fault = item["fault"].to_s
      return nil if item["kind"].to_s == "instruction"
      return nil if CAPABILITY_FAULTS.include?(fault) && item["tools_label"].to_s != "failing tools"

      title = case fault
      when "tool_error" then "Tools error in use: #{Array(item["tools"]).map { |tool| tool["name"] }.first(3).join(", ")}"
      when "run_error" then "Runs fail outright"
      when "low_quality" then "Answers score below the pass threshold"
      when "missing_content" then "Answers omit content the scenarios require"
      when "forbidden_content" then "Answers contain content the scenarios forbid"
      else "#{fault.humanize}: #{item["count"]} scenarios"
      end

      {
        "kind" => fault == "tool_error" ? "fault" : "quality",
        "title" => title,
        "detail" => item["recommendation"].to_s,
        "evidence" => evidence_for(item)
      }
    end

    def metric_limitations
      metrics = metrics_section
      return [] if metrics.nil?

      items = []

      if metrics["error_rate"].to_f > ERROR_RATE_LIMIT
        items << {
          "kind" => "reliability",
          "title" => "#{metrics["error_rate"]}% of production requests error",
          "detail" => "Over #{metrics["requests"]} requests in the last #{metrics["window"]}. " \
                      "Reproduce before changing behaviour, or the change will be judged against a broken baseline.",
          "evidence" => { "fault" => "error_rate", "count" => metrics["errors"].to_i }
        }
      end

      if metrics["p95_ms"].to_i > P95_LIMIT_MS
        items << {
          "kind" => "latency",
          "title" => "p95 latency is #{metrics["p95_ms"]}ms",
          "detail" => "Adding tools or context will make this worse; measure after each change.",
          "evidence" => { "fault" => "latency", "count" => metrics["p95_ms"].to_i }
        }
      end

      items
    end

    def failing_scenarios
      faulted_results.first(MAX_FAILING_SCENARIOS).map do |result|
        {
          "key" => result.scenario&.key,
          "group" => result.scenario&.group,
          "prompt" => result.scenario&.prompt,
          "model" => result.model,
          "status" => result.status,
          "fault" => result.fault,
          "recommendation" => result.recommendation,
          "tools_called" => result.tool_names,
          "error_message" => result.error_message
        }.compact
      end
    end

    def metrics_section
      return @metrics_section if defined?(@metrics_section)

      @metrics_section = build_metrics
    end

    def build_metrics
      return nil if @agent.nil?

      metrics = MetricsReport.new(
        traces: trace_scope,
        agents: [ @agent ],
        range: "24h",
        agent: @agent.telemetry_agent_class
      )
      totals = metrics.totals
      return nil if totals[:requests].to_i.zero?

      {
        "window" => "24h",
        "requests" => totals[:requests],
        "errors" => totals[:errors],
        "error_rate" => totals[:error_rate],
        "p50_ms" => totals[:p50_ms],
        "p95_ms" => totals[:p95_ms],
        "cost" => totals[:cost],
        "tokens" => totals[:tokens],
        "tool_calls" => totals[:tool_calls],
        "tool_errors" => totals[:tool_errors],
        "tool_error_rate" => totals[:tool_error_rate],
        "errors_by_type" => metrics.errors_by_type.to_h { |entry| [ entry[:type].to_s, entry[:count] ] }
      }
    rescue StandardError => e
      # Telemetry is optional: an install with no traces table, or a query
      # this adapter cannot run, costs the brief its metrics section, not
      # the session.
      Rails.logger.warn("[ActionAgent] code session brief could not read metrics: #{e.message}")
      nil
    end

    def trace_scope
      return @traces if @traces

      ActionAgent.multi_tenant? ? ActionAgent.trace_model.for_account(ActionAgent.tenant_for(@owner)) : ActionAgent.trace_model.all
    end

    def code_agent_section
      entry = CodeAgentCatalog.find(@tool)
      return { "tool" => @tool, "name" => @tool, "needs" => [], "limitations" => [] } if entry.nil?

      present, missing = credential_status(entry)

      {
        "tool" => entry.key,
        "name" => entry.name,
        "vendor" => entry.vendor,
        "headless" => entry.headless?,
        "experimental" => entry.experimental?,
        "needs" => entry.needs,
        "limitations" => entry.limitations,
        "docs_url" => entry.docs_url,
        "credentials_present" => present,
        "credentials_missing" => missing
      }
    end

    # Names only, never values: whether each any-of group can be satisfied
    # from the owner's provider keys, from GitHub access, or from the
    # process environment on a single-tenant install.
    def credential_status(entry)
      present = []
      missing = []

      entry.credentials.each do |group|
        names = Array(group).map(&:to_s)
        satisfied = names.find { |name| credential_available?(name) }
        satisfied ? present << satisfied : missing << names
      end

      [ present, missing ]
    end

    PROVIDER_FOR_CREDENTIAL = {
      "ANTHROPIC_API_KEY" => "anthropic",
      "CLAUDE_CODE_OAUTH_TOKEN" => "anthropic",
      "OPENAI_API_KEY" => "openai",
      "OPENROUTER_API_KEY" => "openrouter"
    }.freeze

    def credential_available?(name)
      if %w[GH_TOKEN GITHUB_TOKEN].include?(name)
        return ActionAgent.github_token_for(@owner).present?
      end

      provider = PROVIDER_FOR_CREDENTIAL[name]
      return false if provider.nil?

      return true if ActionAgent.provider_credentials(@owner, provider).present?

      !ActionAgent.multi_tenant? && ENV[name].present?
    rescue StandardError
      false
    end

    def sandbox_section
      {
        "backend" => backend_name,
        "network_mode" => @network_mode,
        "github_access" => @github_access,
        "repository" => @repository,
        "workspace_path" => @repository ? "/workspace/repo" : "/workspace",
        "features" => backend_features,
        "constraints" => constraints
      }
    end

    def backend_name
      return @backend.backend_name if @backend.respond_to?(:backend_name)

      @backend.to_s.presence || CodeSessionOrchestrator.default_backend
    end

    def backend_features
      return @backend.features if @backend.respond_to?(:features)

      {}
    end

    def constraints
      list = []

      list << case @network_mode
      when "restricted" then "Network is restricted: only what the sandbox profile allows is reachable, so installing new packages may fail."
      when "allowlist" then "Network is on an allowlist: GitHub, the usual package registries and the provider APIs are reachable, nothing else is."
      else "Network is open: the sandbox can reach anything this host can."
      end

      list << case @github_access
      when "write" then "GitHub access is read-write: commit on a branch and open a pull request, never push to the default branch."
      when "read" then "GitHub access is read-only: clone and read, but pushing and opening pull requests will fail."
      else "No GitHub token: only public repositories can be cloned, and nothing can be pushed."
      end

      list << "No host secrets are mounted and SSH agent forwarding is off, so credentials outside this brief are unavailable."
      list << "The container is discarded when the session ends: anything not committed or reported is lost."
      list
    end

    # Renders a brief hash as the BRIEF.md a coding agent reads. Kept apart
    # from the compilation so a persisted brief renders identically later.
    class Markdown
      def initialize(brief, session: nil)
        @brief = brief
        @session = session
      end

      def to_s
        sections = [
          header, agent_section, needs_section, limitations_section,
          scenarios_section, metrics_section, sandbox_section, task_section
        ]
        "#{sections.compact.join("\n\n")}\n"
      end

      private

      def code_agent = @brief["code_agent"] || {}

      def header
        name = code_agent["name"].presence || "the coding agent"
        "# Brief for #{name}\n\nCompiled #{@brief["generated_at"]} by Active Agent from this agent's evaluations and telemetry."
      end

      def agent_section
        agent = @brief["agent"]
        return nil if agent.blank?

        lines = [ "## Agent under improvement", "" ]
        lines << "- Name: #{agent["name"]}"
        lines << "- Runs on: #{agent["provider"]}/#{agent["model"]}"
        lines << "- Tools: #{list(agent["tools"])}"
        lines << "- MCP servers: #{list(agent["mcp_servers"])}"

        evaluation = @brief["evaluation"]
        if evaluation.present?
          rate = evaluation["pass_rate"]
          lines << "- Evaluation: #{evaluation["name"]} (run #{evaluation["run_id"]}, #{evaluation["kind"]})" \
                   "#{rate ? ", #{evaluation["passed"]}/#{evaluation["scenarios"]} scenarios passing (#{rate}%)" : ""}"
        end

        if agent["instructions_excerpt"].present?
          lines += [ "", "Its instructions begin:", "", "```", agent["instructions_excerpt"], "```" ]
        end

        lines.join("\n")
      end

      def needs_section
        items = Array(@brief["needs"])
        return "## What its evaluations say it needs\n\nNothing: no evaluation run has found a capability gap." if items.empty?

        lines = [ "## What its evaluations say it needs", "" ]
        items.each { |item| lines << bullet(item) }
        lines.join("\n")
      end

      def limitations_section
        items = Array(@brief["limitations"])
        return nil if items.empty?

        lines = [ "## Known limitations", "" ]
        items.each { |item| lines << bullet(item) }
        lines.join("\n")
      end

      def bullet(item)
        evidence = item["evidence"] || {}
        parts = []
        parts << "#{evidence["fault"]} x#{evidence["count"]}" if evidence["fault"].present?
        parts << "scenarios #{Array(evidence["scenario_keys"]).join(", ")}" if Array(evidence["scenario_keys"]).any?
        suffix = parts.any? ? " (#{parts.join("; ")})" : ""

        "- **#{item["title"]}** #{item["detail"]}#{suffix}".squeeze(" ")
      end

      def scenarios_section
        rows = Array(@brief["failing_scenarios"])
        return nil if rows.empty?

        lines = [ "## Failing scenarios", "", "| Scenario | Model | Fault | What would fix it |", "| --- | --- | --- | --- |" ]
        rows.each do |row|
          lines << "| #{cell(row["key"])} | #{cell(row["model"])} | #{cell(row["fault"])} | #{cell(row["recommendation"])} |"
        end
        lines << ""
        lines << "The prompts behind these are in the dashboard; each was replayed through the agent as written."
        lines.join("\n")
      end

      def cell(value)
        value.to_s.gsub("|", "\\|").gsub(/\s+/, " ").strip
      end

      def metrics_section
        metrics = @brief["metrics"]
        return nil if metrics.blank?

        lines = [ "## Production signal (last #{metrics["window"]})", "" ]
        lines << "- Requests: #{metrics["requests"]} (#{metrics["errors"]} errors, #{metrics["error_rate"]}%)"
        lines << "- Latency: p50 #{metrics["p50_ms"]}ms, p95 #{metrics["p95_ms"]}ms"
        lines << "- Tool calls: #{metrics["tool_calls"]} (#{metrics["tool_errors"]} errored)"
        lines << "- Estimated cost: $#{metrics["cost"]}"
        lines.join("\n")
      end

      def sandbox_section
        sandbox = @brief["sandbox"] || {}
        lines = [ "## Your sandbox", "" ]
        lines << "- Working copy: #{sandbox["workspace_path"] || "/workspace"}#{sandbox["repository"] ? " (#{sandbox["repository"]})" : ""}"
        lines << "- This brief: /brief/BRIEF.md"
        Array(sandbox["constraints"]).each { |constraint| lines << "- #{constraint}" }

        needs = Array(code_agent["needs"])
        limits = Array(code_agent["limitations"])
        missing = Array(code_agent["credentials_missing"]).map { |group| Array(group).join(" or ") }
        lines << "- Missing credentials: #{missing.join("; ")}" if missing.any?
        lines += [ "", "You need: #{needs.join(" ")}" ] if needs.any?
        lines << "Your limits here: #{limits.join(" ")}" if limits.any?

        lines.join("\n")
      end

      def task_section
        task = @brief["task"].presence || @session&.task
        return nil if task.blank?

        "## Task\n\n#{task}"
      end

      def list(values)
        values = Array(values).map(&:to_s).reject(&:blank?)
        values.any? ? values.join(", ") : "none"
      end
    end
  end
end
