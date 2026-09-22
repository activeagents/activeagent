# frozen_string_literal: true

# Loaded by an explicit `require "active_agent/evals/ruby_llm"` — never by
# `require "active_agent/evals"` — so the evaluation module itself stays free
# of the ruby_llm gem.
require "ruby_llm"
require_relative "../evals"

module ActiveAgent
  module Evals
    # The RubyLLM side of an evaluation: a Judge that asks a RubyLLM chat for
    # its completions, and a Replay built from the messages an `acts_as_chat`
    # conversation stored. Both are the glue a host that drives RubyLLM chats
    # would otherwise write itself.
    #
    #   require "active_agent/evals/ruby_llm"
    #
    #   judge = ActiveAgent::Evals::RubyLLM.judge(label: "claude-opus-5", model: "claude-opus-5",
    #                                             provider: :anthropic, correlation: correlation)
    #
    #   report = correlation.with_run("suite" => "support") do |metadata|
    #     ActiveAgent::Evals::Runner.new(
    #       scenarios: scenarios, models: models, metadata: metadata, judge: judge,
    #       around_evaluation: correlation,
    #       replay: ->(scenario, spec) {
    #         chat = correlation.replay { SupportChat.run(scenario.prompt, model: spec.model) }
    #         ActiveAgent::Evals::RubyLLM.replay(chat.messages.order(:id), duration_ms: chat.elapsed_ms)
    #       }
    #     ).call
    #   end
    module RubyLLM
      class << self
        # Builds a Judge whose completions come from a RubyLLM chat.
        #
        # `context` is anything answering to `#chat` the way RubyLLM does: the
        # `::RubyLLM` module itself, or a `RubyLLM.context` built with the
        # host's own keys (see `ActionAgent::ProviderKey.apply_to`). With a
        # `correlation`, every call is traced through `Correlation#judge` under
        # the kind it serves, so the judge trace lands on the result it graded.
        #
        # @param label [String] how reports name the judge
        # @param model [String] the judge model
        # @param provider [Symbol, String] the RubyLLM provider serving it
        # @param context [#chat] where `chat` is called; defaults to `::RubyLLM`
        # @param correlation [Correlation, nil] traces each call as a judge call
        # @param assume_model_exists [Boolean] skip RubyLLM's model registry check
        # @param chat_options [Hash] any other `chat` keyword (`protocol:`, ...)
        # @return [Judge]
        def judge(label:, model:, provider:, context: ::RubyLLM, correlation: nil, assume_model_exists: true,
                  **chat_options)
          Judge.new(label: label) do |instructions:, prompt:, kind:|
            complete = lambda do
              context.chat(model: model, provider: provider.to_sym, assume_model_exists: assume_model_exists,
                           **chat_options)
                     .with_instructions(instructions)
                     .ask(prompt)
                     .content
            end

            correlation ? correlation.judge(kind.to_s, &complete) : complete.call
          end
        end

        # Builds a Replay from the ordered messages of a RubyLLM conversation —
        # `acts_as_chat` message records, `RubyLLM::Message` values, or anything
        # shaped like them (`role`, `content`, `tool_calls`, `tool_call_id`, and
        # `input_tokens`/`output_tokens` or `tokens`).
        #
        # Tool calls are every message's calls in id order, each
        # `{ "name", "arguments", "error", "detail" }`. A call is errored when
        # the `tool` message answering it (matched on `tool_call_id`) holds JSON
        # with an `"error"` key — the shape an MCP tool failure is reported in —
        # and `detail` is then that error. Tokens sum the assistant messages,
        # reading `input_tokens`/`output_tokens` (RubyLLM 1.x) or
        # `tokens.input`/`tokens.output` (RubyLLM 2.x). The answer defaults to
        # the last assistant message's content.
        #
        # @param messages [Array, #to_a] the conversation's messages, oldest first
        # @param answer [String, nil] overrides the last assistant message's content
        # @param duration_ms [Numeric, nil]
        # @param error [String, Exception, nil] when the run raised before answering
        # @param metadata [Hash] carried onto the Result
        # @return [Replay]
        def replay(messages, answer: nil, duration_ms: nil, error: nil, metadata: {})
          messages = messages.to_a
          tokens = token_totals(messages)

          Replay.new(
            answer: answer.nil? ? last_assistant_content(messages) : answer,
            tool_calls: extract_tool_calls(messages),
            duration_ms: duration_ms,
            input_tokens: tokens[:input],
            output_tokens: tokens[:output],
            error: error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error,
            metadata: metadata
          )
        end

        private

        def extract_tool_calls(messages)
          results_by_call = messages.select { |message| role_of(message) == "tool" }
                                    .to_h { |message| [ message.tool_call_id, message ] }

          messages.flat_map { |message| tool_calls_of(message) }.sort_by(&:id).map do |tool_call|
            result = results_by_call[tool_call.id]
            payload = parse_json(result&.content)
            errored = payload.is_a?(Hash) && payload.key?("error")

            {
              "name" => tool_call.name.to_s,
              "arguments" => tool_call.arguments,
              "error" => errored,
              "detail" => errored ? payload["error"].to_s : nil
            }.compact
          end
        end

        # `tool_calls` is a has_many on a RubyLLM 1.x record, a Hash keyed by
        # call id on a RubyLLM 2.x record or a RubyLLM::Message, and nil on a
        # message with no calls.
        def tool_calls_of(message)
          return [] unless message.respond_to?(:tool_calls)

          calls = message.tool_calls
          calls = calls.values if calls.is_a?(Hash)
          calls.nil? ? [] : calls.to_a
        end

        def token_totals(messages)
          assistants = messages.select { |message| role_of(message) == "assistant" }
          input = assistants.sum { |message| token_count(message, :input) }
          output = assistants.sum { |message| token_count(message, :output) }
          { input: input, output: output }
        end

        def token_count(message, direction)
          count = if message.respond_to?(:"#{direction}_tokens")
            message.public_send(:"#{direction}_tokens")
          elsif message.respond_to?(:tokens) && message.tokens.respond_to?(direction)
            message.tokens.public_send(direction)
          end
          count.to_i
        end

        def last_assistant_content(messages)
          last = messages.reverse.find { |message| role_of(message) == "assistant" }
          last&.content
        end

        def role_of(message)
          message.role.to_s
        end

        def parse_json(content)
          return nil if content.blank?

          JSON.parse(content.to_s)
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
