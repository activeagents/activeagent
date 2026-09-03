# frozen_string_literal: true

module ActionAgent
  # Explains why a scenario did not pass and what would fix it.
  #
  # The fault is assigned deterministically from the replay's evidence, in
  # the order of EvaluationScenarioResult::FAULTS — the most mechanical cause
  # wins, so a run that crashed is a `run_error` even if its (empty) answer
  # would also have failed a content check. Each fault comes with a
  # recommendation written from the evidence; when a judge model is available
  # the caller can ask it to refine that recommendation (see `refine_with`).
  #
  # Returns nil for a passing result.
  class FaultDiagnosis
    # Phrases an agent uses when nothing in its toolset covers the task.
    CAPABILITY_REFUSALS = [
      /\bI(?:'m| am)? (?:do not |don't |cannot |can't |unable to |not able to )(?:currently )?(?:have|access|retrieve|look up|query|check|see|find|view|search)\b/i,
      /\b(?:no|don't have (?:a|any)) tools? (?:is |are )?(?:available|that can|to)\b/i,
      /\bnot (?:something|able|possible) (?:I|to) (?:can|am able to )?(?:do|access|retrieve|look up)\b/i,
      /\bI (?:don't|do not) have (?:the ability|a way|access|visibility|the tools?)\b/i,
      /\boutside (?:of )?(?:my|the) (?:capabilities|available tools|scope)\b/i,
      /\bcan(?:'|no)t (?:be )?(?:done|determined|answered) with (?:the|my) (?:current|available) tools\b/i
    ].freeze

    Result = Struct.new(
      :fault, :summary, :recommendation, :evidence,
      keyword_init: true
    ) do
      def to_h
        {
          "fault" => fault,
          "summary" => summary,
          "recommendation" => recommendation,
          "evidence" => evidence
        }
      end
    end

    # @param scenario [EvaluationScenario]
    # @param agent_run [AgentRun] the replay
    # @param tool_calls [Array<Hash>] { "name", "arguments", "error", "duration_ms" } per call
    # @param scores [Hash] criterion key => 0.0..1.0 (nil when unscorable)
    # @param score [Float, nil] the result's overall score
    # @param roster [Array<Hash>] the agent's tool definitions ({ name:, description: })
    # @param threshold [Float] the pass threshold for `score`
    def self.call(scenario:, agent_run:, tool_calls:, scores:, score:, roster:, threshold:)
      new(scenario:, agent_run:, tool_calls:, scores:, score:, roster:, threshold:).call
    end

    def initialize(scenario:, agent_run:, tool_calls:, scores:, score:, roster:, threshold:)
      @scenario = scenario
      @agent_run = agent_run
      @tool_calls = tool_calls
      @scores = scores || {}
      @score = score
      @roster = roster
      @threshold = threshold
    end

    def call
      run_error || tool_error || missing_capability || expected_tool_not_called ||
        forbidden_content || missing_content || low_quality
    end

    private

    def output
      @agent_run.output.to_s
    end

    def called_tools
      @tool_calls.map { |call| call["name"].to_s }
    end

    def roster_names
      @roster.map { |tool| tool[:name] || tool["name"] }.map(&:to_s)
    end

    def run_error
      if @agent_run.failed?
        message = @agent_run.error_message.to_s
        return result(
          "run_error",
          "The run failed before the agent answered: #{message.truncate(200)}",
          run_error_recommendation(message),
          "error" => message.truncate(1_000)
        )
      end

      return nil if output.present?

      result(
        "run_error",
        "The agent returned an empty answer.",
        "The provider returned no content. Check the model name is valid for the provider and that " \
        "max_tokens leaves room for an answer after the tool calls.",
        "error" => "empty output"
      )
    end

    def run_error_recommendation(message)
      case message
      when /credentials|api key|access_token|unauthori[sz]ed|401/i
        "Add credentials for the provider this run used (Settings → Provider API Keys) or configure them " \
        "in config/active_agent.yml before comparing this model."
      when /model.*(not found|does not exist|unknown|unsupported)|404/i
        "The model name was rejected by the provider. Check the spelling against the provider's catalog, " \
        "or prefix it with the provider (`ollama/qwen3:8b`) so it runs where it exists."
      when /rate limit|429|overloaded|529/i
        "The provider throttled the run. Re-run the failed scenarios; if it recurs, run fewer scenarios " \
        "per batch or compare fewer models at once."
      else
        "Inspect the linked run's error and backtrace. A failure here is infrastructure — it says nothing " \
        "about the agent's answer quality yet."
      end
    end

    def tool_error
      failed = @tool_calls.select { |call| call["error"] }
      return nil if failed.empty?

      names = failed.map { |call| call["name"] }.uniq
      detail = failed.first["detail"].to_s.truncate(300)
      result(
        "tool_error",
        "Tool #{names.join(', ')} returned an error while answering.",
        "Fix the failing tool before judging the answer: #{names.join(', ')} errored with " \
        "\"#{detail}\". If the arguments look wrong, tighten the tool's parameter descriptions " \
        "so the model calls it correctly; if the tool itself broke, fix its implementation.",
        "tools" => names, "detail" => detail, "arguments" => failed.first["arguments"]
      )
    end

    def missing_capability
      return nil unless CAPABILITY_REFUSALS.any? { |pattern| output.match?(pattern) }
      return nil if called_tools.any? && @score.to_f >= @threshold

      expected = @scenario.expected_tools
      recommendation =
        if expected.any? && (expected - roster_names).any?
          "The agent said it cannot do this, and the expected tool(s) #{(expected - roster_names).join(', ')} " \
          "are not in its toolset. Add or enable them for this agent."
        elsif roster_names.empty?
          "The agent has no tools, so it can only answer from its instructions. Give it a tool that reads " \
          "the data this question needs (an MCP server or a server-side tool)."
        else
          "None of the agent's tools (#{roster_names.join(', ')}) covers this task. Add a tool that does, " \
          "or, if one of them should, rewrite its description so the model recognises when to use it."
        end

      result(
        "missing_capability",
        "The agent said it lacks the ability to perform this task.",
        recommendation,
        "refusal" => refusal_excerpt, "tools_available" => roster_names, "tools_called" => called_tools
      )
    end

    def refusal_excerpt
      pattern = CAPABILITY_REFUSALS.find { |candidate| output.match?(candidate) }
      match = output.match(pattern)
      return nil unless match

      start = [ match.begin(0) - 80, 0 ].max
      output[start, 260].to_s.strip
    end

    def expected_tool_not_called
      expected = @scenario.expected_tools
      return nil if expected.empty? || (expected & called_tools).any?

      unavailable = expected - roster_names
      recommendation =
        if unavailable.any?
          "The scenario expects #{unavailable.join(', ')}, which this agent does not have. Enable the tool " \
          "on the agent (or add the MCP server that provides it) and re-run."
        elsif called_tools.any?
          "The agent answered with #{called_tools.uniq.join(', ')} instead of #{expected.join(', ')}. " \
          "Sharpen the descriptions of both so the model can tell them apart, or say in the instructions " \
          "which tool answers this kind of question."
        else
          "#{expected.join(', ')} is available but the agent answered without calling any tool. Tell it " \
          "in the instructions to prefer tool-backed answers for this kind of question, and check the " \
          "tool's description says what it returns."
        end

      result(
        "expected_tool_not_called",
        "Expected #{expected.join(' or ')} to be called; the agent called #{called_tools.uniq.presence&.join(', ') || 'nothing'}.",
        recommendation,
        "expected" => expected, "called" => called_tools, "unavailable" => unavailable
      )
    end

    def forbidden_content
      matched = @scenario.forbidden_patterns.select { |pattern| match_pattern?(pattern) }
      return nil if matched.empty?

      result(
        "forbidden_content",
        "The answer contains content the scenario forbids: #{matched.join(', ')}.",
        "Add an explicit instruction against this (\"#{matched.first}\") and, if the phrase comes from a " \
        "tool result, filter it in the tool rather than relying on the model to omit it.",
        "matched" => matched
      )
    end

    def missing_content
      missing = @scenario.expected_patterns.reject { |pattern| match_pattern?(pattern) }
      return nil if missing.empty?

      result(
        "missing_content",
        "The answer is missing expected content: #{missing.join(', ')}.",
        if called_tools.empty? && roster_names.any?
          "The agent answered without calling a tool, so it could not have found \"#{missing.first}\". " \
          "Instruct it to use its tools for this kind of question."
        else
          "The answer never mentions \"#{missing.first}\". Check whether the tool result contained it — " \
          "if it did, the instructions should ask for it explicitly; if not, the tool needs to return it."
        end,
        "missing" => missing
      )
    end

    def low_quality
      return nil if @score.nil? || @score >= @threshold

      weakest = @scores.compact.min_by { |_, value| value }
      result(
        "low_quality",
        "Scored #{@score.round(2)} against a pass threshold of #{@threshold}" \
        "#{weakest ? ", weakest on #{weakest.first} (#{weakest.last.round(2)})" : ''}.",
        if weakest
          "Read the answer against the #{weakest.first.to_s.humanize.downcase} criterion and adjust the " \
          "instructions where it falls short. A criterion that keeps scoring low across scenarios points " \
          "at the instructions; one that fails on one scenario points at that task's tooling."
        else
          "Compare this answer with a passing one for a similar scenario and adjust the instructions."
        end,
        "scores" => @scores
      )
    end

    def match_pattern?(pattern)
      output.match?(Regexp.new(pattern, Regexp::IGNORECASE))
    rescue RegexpError
      output.downcase.include?(pattern.downcase)
    end

    def result(fault, summary, recommendation, evidence = {})
      Result.new(fault: fault, summary: summary, recommendation: recommendation, evidence: evidence.compact)
    end
  end
end
