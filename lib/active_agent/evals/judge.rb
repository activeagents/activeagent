# frozen_string_literal: true

module ActiveAgent
  module Evals
    # A second model that scores answers, refines recommendations, and picks a
    # winner. The gem owns the prompts and the parsing; the caller supplies the
    # one thing that differs per stack — how to get a completion:
    #
    #   judge = ActiveAgent::Evals::Judge.new(label: "claude-opus-5") do |instructions:, prompt:|
    #     RubyLLM.chat(model: "claude-opus-5").with_instructions(instructions).ask(prompt).content
    #   end
    #
    # Every method returns nil when the judge fails or answers unusably, so an
    # evaluation degrades to rule scoring rather than aborting.
    class Judge
      SCORE_INSTRUCTIONS = "You are an impartial evaluation judge. Respond ONLY with JSON: " \
                           '{"score": <float between 0.0 and 1.0>}'
      RECOMMEND_INSTRUCTIONS = "You diagnose why an AI agent failed a task and recommend the fix. Respond ONLY with JSON."
      VERDICT_INSTRUCTIONS = "You are an impartial evaluation judge comparing model cohorts. Respond ONLY with JSON."

      attr_reader :label

      # @param label [String] how reports name the judge (usually its model)
      # @yieldparam instructions [String] the system prompt
      # @yieldparam prompt [String] the user prompt
      # @yieldreturn [String] the completion text
      def initialize(label:, &generate)
        raise ArgumentError, "Judge.new needs a block that returns the model's completion" unless generate

        @label = label
        @generate = generate
      end

      # Scores `answer` against one llm_judge criterion, 0.0..1.0.
      def score_criterion(criterion:, prompt:, answer:)
        return nil if answer.blank?

        guidance = criterion.dig("config", "prompt").presence || criterion["key"].to_s.humanize
        parse_score(ask(SCORE_INSTRUCTIONS, <<~PROMPT))
          Criterion: #{guidance}

          The user asked:
          ---
          #{prompt.to_s.truncate(1_500)}
          ---

          The agent answered:
          ---
          #{answer.to_s.truncate(4_000)}
          ---

          Score the answer against the criterion from 0.0 (fails completely) to 1.0 (fully satisfies).
          Respond only with JSON: {"score": <float>}
        PROMPT
      end

      # Scores how well `answer` accomplishes the scenario's task, 0.0..1.0 —
      # the single-criterion judgement for a scenario with no criteria of its own.
      def score_task(scenario:, answer:)
        return nil if answer.blank?

        parse_score(ask(SCORE_INSTRUCTIONS, <<~PROMPT))
          A user asked an assistant:
          ---
          #{scenario.prompt}
          ---
          #{"Context for the evaluator: #{scenario.notes.truncate(300)}\n" if scenario.notes.present?}
          The assistant answered:
          ---
          #{answer.to_s.truncate(4_000)}
          ---

          Score from 0.0 (the task was not done — a refusal, a guess, or an unrelated answer) to 1.0 (the task
          was done with specific, tool-backed data and a clear next step for the user).
          Respond only with JSON: {"score": <float>}
        PROMPT
      end

      # Asks what to change so the scenario passes. Returns a hash with any of
      # `recommendation`, `suggested_tool` (`{ "name", "description" }`) and
      # `instruction_change`, or nil.
      def recommend(scenario:, replay:, diagnosis:, available_tools: {}, instructions: nil)
        roster = available_tools.to_h.map { |name, description| "- #{name}: #{description.to_s.truncate(160)}" }.join("\n")
        calls = replay.tool_calls.map do |call|
          "- #{call['name']}#{' (errored)' if call['error']}: #{call['arguments'].to_json.truncate(200)}"
        end.join("\n")

        parsed = parse_object(ask(RECOMMEND_INSTRUCTIONS, <<~PROMPT))
          An AI agent failed one evaluation scenario. Recommend the fix.

          Agent instructions:
          ---
          #{instructions.to_s.truncate(2_000).presence || '(no instructions configured)'}
          ---

          Tools available to the agent:
          #{roster.presence || '(none)'}

          Scenario (the user's message):
          #{scenario.prompt}
          #{"Expected tools: #{scenario.expected_tools.join(', ')}" if scenario.expected_tools.any?}
          #{"Notes: #{scenario.notes.truncate(300)}" if scenario.notes.present?}

          Tools the agent called:
          #{calls.presence || '(none)'}

          The agent's answer:
          ---
          #{replay.answer.to_s.truncate(2_500).presence || '(empty)'}
          ---

          Detected fault: #{diagnosis.fault} — #{diagnosis.summary}

          Say what to change so this scenario passes. If the agent lacks a tool for the task, describe the
          tool to add. If the tools suffice, say what to change in the instructions.
          Respond ONLY with JSON:
          {"recommendation": "<two sentences at most>",
           "suggested_tool": {"name": "snake_case_name", "description": "what it returns"} or null,
           "instruction_change": "<the sentence to add or change>" or null}
        PROMPT

        parsed = parsed&.slice("recommendation", "suggested_tool", "instruction_change")&.compact
        return nil if parsed.blank?

        parsed["suggested_tool"] = suggested_tool(parsed["suggested_tool"]) if parsed.key?("suggested_tool")
        parsed.compact.presence
      end

      # Picks the model that best accomplishes the agent's goals from the
      # per-model summaries (Report#summary_by_model). Returns
      # `{ "winner", "rationale" }` or nil; a winner that is not one of the
      # compared models is discarded.
      def verdict(summaries, instructions: nil)
        lines = summaries.map do |label, stats|
          faults = (stats["faults"] || {}).map { |fault, count| "#{fault}×#{count}" }.join(", ")
          "#{label}: pass rate #{stats['pass_rate']}%, mean score #{stats['avg_score'] || 'n/a'}, " \
            "avg latency #{stats['avg_duration_ms'] || 'n/a'}ms, cost $#{stats['cost'] || 'n/a'}" \
            "#{", faults: #{faults}" if faults.present?}"
        end

        parsed = parse_object(ask(VERDICT_INSTRUCTIONS, <<~PROMPT))
          An AI agent ran the same scenarios under several models. Its goals:
          ---
          #{instructions.to_s.truncate(1_000).presence || '(no instructions configured)'}
          ---

          Results per model:
          #{lines.join("\n")}

          Which model best accomplishes the agent's goals, weighing task completion first and cost and
          latency second? Respond ONLY with JSON: {"winner": "<model>", "rationale": "<at most two sentences>"}
        PROMPT

        return nil unless parsed && summaries.key?(parsed["winner"])

        { "winner" => parsed["winner"], "rationale" => parsed["rationale"].to_s }
      end

      private

      # The judge is asked for `{ "name", "description" }`; a bare string is
      # taken as the name, and anything else is dropped rather than rendered
      # as an empty tool.
      def suggested_tool(tool)
        case tool
        when Hash
          { "name" => tool["name"].to_s, "description" => tool["description"].to_s } if tool["name"].present?
        when String
          { "name" => tool, "description" => "" } if tool.present?
        end
      end

      def ask(instructions, prompt)
        @generate.call(instructions: instructions, prompt: prompt).to_s
      rescue StandardError => e
        warn_failure(e)
        nil
      end

      def warn_failure(error)
        message = "[ActiveAgent::Evals] judge #{label} failed: #{error.class}: #{error.message}"
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.warn(message)
        else
          warn(message)
        end
      end

      def parse_score(content)
        match = content.to_s.match(/"score"\s*:\s*(\d+(?:\.\d+)?)/)
        match && match[1].to_f.clamp(0.0, 1.0)
      end

      def parse_object(content)
        json = content.to_s[/\{.*\}/m]
        return nil unless json

        parsed = JSON.parse(json)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end
    end
  end
end
