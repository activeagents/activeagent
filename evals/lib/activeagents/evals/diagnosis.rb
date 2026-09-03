# frozen_string_literal: true

module ActiveAgents
  module Evals
    # Explains why a scenario did not pass and what would fix it.
    #
    # The fault is assigned from the replay's evidence, the most mechanical
    # cause first, so a run that crashed is a `run_error` even if its empty
    # answer would also have failed a content check:
    #
    #   run_error                — the run raised, or the agent returned nothing
    #   tool_error               — a tool the agent called returned an error
    #   missing_capability       — the agent said no tool covers the task
    #   expected_tool_not_called — the scenario expects a tool the agent did not call
    #   forbidden_content        — the answer contains a pattern the scenario forbids
    #   missing_content          — the answer lacks a pattern the scenario expects
    #   low_quality              — the answer scored below the threshold
    #
    # Each fault carries a recommendation written from the evidence; a Judge
    # can replace it with one that names the tool to add (Runner does this).
    # Returns nil for a passing result.
    class Diagnosis
      FAULTS = %w[
        run_error tool_error missing_capability expected_tool_not_called
        forbidden_content missing_content low_quality
      ].freeze

      # Phrasings an agent uses when nothing in its toolset covers the task.
      REFUSED_VERBS = "have|access|retrieve|look up|query|check|see|find|view|search"
      CAPABILITY_REFUSALS = [
        /\bI(?:'m| am)? (?:do not |don't |cannot |can't |unable to |not able to )(?:currently )?(?:#{REFUSED_VERBS})\b/i,
        /\b(?:no|don't have (?:a|any)) tools? (?:is |are )?(?:available|that can|to)\b/i,
        /\bnot (?:something|able|possible) (?:I|to) (?:can|am able to )?(?:do|access|retrieve|look up)\b/i,
        /\bI (?:don't|do not) have (?:the ability|a way|access|visibility|the tools?)\b/i,
        /\boutside (?:of )?(?:my|the) (?:capabilities|available tools|scope)\b/i,
        /\bcan(?:'|no)t (?:be )?(?:done|determined|answered) with (?:the|my) (?:current|available) tools\b/i
      ].freeze

      Result = Struct.new(:fault, :summary, :recommendation, :evidence, keyword_init: true) do
        def to_h
          {
            "fault" => fault,
            "summary" => summary,
            "recommendation" => recommendation,
            "evidence" => evidence
          }
        end
      end

      # @param scenario [Scenario]
      # @param replay [Replay]
      # @param scores [Hash] criterion key => 0.0..1.0 (nil when unscorable)
      # @param score [Float, nil] the mean score
      # @param available_tools [Array<String>] tool names the agent could call
      # @param threshold [Float] the pass threshold for `score`
      # @param agent_name [String] how the recommendations refer to the agent
      def self.call(scenario:, replay:, scores:, score:, available_tools:, threshold: PASS_THRESHOLD, agent_name: "The agent")
        new(scenario:, replay:, scores:, score:, available_tools:, threshold:, agent_name:).call
      end

      def initialize(scenario:, replay:, scores:, score:, available_tools:, threshold: PASS_THRESHOLD, agent_name: "The agent")
        @scenario = scenario
        @replay = replay
        @scores = scores || {}
        @score = score
        @available_tools = Array(available_tools).map(&:to_s)
        @threshold = threshold
        @agent_name = agent_name
      end

      def call
        run_error || tool_error || missing_capability || expected_tool_not_called ||
          forbidden_content || missing_content || low_quality
      end

      private

      def answer
        @replay.answer.to_s
      end

      def called_tools
        @replay.tool_names
      end

      def agent
        @agent_name
      end

      def run_error
        if @replay.errored?
          message = @replay.error.to_s
          return result("run_error", "The run failed before #{agent.downcase} answered: #{message.truncate(200)}",
                        run_error_recommendation(message), "error" => message.truncate(1_000))
        end
        return nil if answer.present?

        result("run_error", "#{agent} returned an empty answer.",
               "The provider returned no content. Check the model name is one the provider serves and that the " \
               "output budget leaves room for an answer after the tool calls.",
               "error" => "empty answer")
      end

      def run_error_recommendation(message)
        case message
        when /credentials|api.?key|access_token|unauthori[sz]ed|401/i
          "Add credentials for the provider this model runs on before comparing it."
        when /model.*(not found|does not exist|unknown|unsupported)|404/i
          "The provider rejected the model name. Check the spelling against the provider's catalog, or prefix " \
          "it with the provider (`ollama/qwen3:8b`) so it runs where it exists."
        when /rate limit|429|overloaded|529/i
          "The provider throttled the run. Re-run the failed scenarios; if it recurs, run fewer scenarios per " \
          "batch or compare fewer models at once."
        else
          "Inspect the run's error. A failure here is infrastructure — it says nothing about the answer yet."
        end
      end

      def tool_error
        failed = @replay.failed_tool_calls
        return nil if failed.empty?

        names = failed.map { |call| call["name"] }.uniq
        detail = failed.first["detail"].to_s.truncate(300)
        result("tool_error", "Tool #{names.join(', ')} returned an error while answering.",
               "Fix the failing tool before judging the answer: #{names.join(', ')} errored with \"#{detail}\". " \
               "If the arguments look wrong, tighten the tool's parameter descriptions so the model calls it " \
               "correctly; if the tool itself broke, fix its implementation.",
               "tools" => names, "detail" => detail, "arguments" => failed.first["arguments"])
      end

      def missing_capability
        return nil unless CAPABILITY_REFUSALS.any? { |pattern| answer.match?(pattern) }
        return nil if called_tools.any? && @score.to_f >= @threshold

        missing = @scenario.expected_tools - @available_tools
        recommendation =
          if missing.any?
            "#{agent} said it cannot do this, and the expected tool(s) #{missing.join(', ')} are not in its " \
            "toolset. Add or enable them."
          elsif @available_tools.empty?
            "#{agent} has no tools, so it can only answer from its instructions. Give it a tool that reads the " \
            "data this task needs."
          else
            "None of the available tools (#{@available_tools.join(', ')}) covers this task. Add a tool that does, " \
            "or, if one of them should, rewrite its description so the model recognises when to use it."
          end

        result("missing_capability", "#{agent} said it lacks the ability to perform this task.", recommendation,
               "refusal" => refusal_excerpt, "tools_available" => @available_tools, "tools_called" => called_tools)
      end

      def refusal_excerpt
        pattern = CAPABILITY_REFUSALS.find { |candidate| answer.match?(candidate) }
        match = answer.match(pattern)
        return nil unless match

        answer[[ match.begin(0) - 80, 0 ].max, 260].to_s.strip
      end

      def expected_tool_not_called
        expected = @scenario.expected_tools
        return nil if expected.empty? || (expected & called_tools).any?

        unavailable = expected - @available_tools
        recommendation =
          if unavailable.any?
            "The scenario expects #{unavailable.join(', ')}, which #{agent.downcase} does not have. Enable the " \
            "tool (or add the server that provides it) and re-run."
          elsif called_tools.any?
            "#{agent} answered with #{called_tools.uniq.join(', ')} instead of #{expected.join(', ')}. Sharpen " \
            "both tools' descriptions so the model can tell them apart, or say in the instructions which tool " \
            "answers this kind of task."
          else
            "#{expected.join(', ')} is available but #{agent.downcase} answered without calling any tool. Tell " \
            "it in the instructions to prefer tool-backed answers for this kind of task, and check the tool's " \
            "description says what it returns."
          end

        result("expected_tool_not_called",
               "Expected #{expected.join(' or ')} to be called; #{agent.downcase} called " \
               "#{called_tools.uniq.presence&.join(', ') || 'nothing'}.",
               recommendation, "expected" => expected, "called" => called_tools, "unavailable" => unavailable)
      end

      def forbidden_content
        matched = @scenario.forbidden_patterns.select { |pattern| Scorer.matches_pattern?(answer, pattern) }
        return nil if matched.empty?

        result("forbidden_content", "The answer contains content the scenario forbids: #{matched.join(', ')}.",
               "Add an explicit instruction against \"#{matched.first}\" and, if the phrase comes from a tool " \
               "result, filter it in the tool rather than relying on the model to omit it.",
               "matched" => matched)
      end

      def missing_content
        missing = @scenario.expected_patterns.reject { |pattern| Scorer.matches_pattern?(answer, pattern) }
        return nil if missing.empty?

        recommendation =
          if called_tools.empty? && @available_tools.any?
            "#{agent} answered without calling a tool, so it could not have found \"#{missing.first}\". " \
            "Instruct it to use its tools for this kind of task."
          else
            "The answer never mentions \"#{missing.first}\". Check whether the tool result contained it — if it " \
            "did, the instructions should ask for it explicitly; if not, the tool needs to return it."
          end

        result("missing_content", "The answer is missing expected content: #{missing.join(', ')}.", recommendation,
               "missing" => missing)
      end

      def low_quality
        return nil if @score.nil? || @score >= @threshold

        weakest = @scores.compact.min_by { |_, value| value }
        summary = "Scored #{@score.round(2)} against a pass threshold of #{@threshold}"
        summary += ", weakest on #{weakest.first} (#{weakest.last.round(2)})" if weakest
        recommendation =
          if weakest
            "Read the answer against the #{weakest.first.to_s.humanize.downcase} criterion and adjust the " \
            "instructions where it falls short. A criterion that keeps scoring low across scenarios points at " \
            "the instructions; one that fails on one scenario points at that task's tooling."
          else
            "Compare this answer with a passing one for a similar scenario and adjust the instructions."
          end

        result("low_quality", "#{summary}.", recommendation, "scores" => @scores)
      end

      def result(fault, summary, recommendation, evidence = {})
        Result.new(fault: fault, summary: summary, recommendation: recommendation, evidence: evidence.compact)
      end
    end
  end
end
