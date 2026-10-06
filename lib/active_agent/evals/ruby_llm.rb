# frozen_string_literal: true

# Loaded by an explicit `require "active_agent/evals/ruby_llm"` — never by
# `require "active_agent/evals"` — so the evaluation module itself stays free
# of the ruby_llm gem.
require "ruby_llm"
require_relative "../evals"

module ActiveAgent
  module Evals
    # The RubyLLM side of an evaluation: a Judge that asks a RubyLLM chat for
    # its completions, and a Replay built from the messages a RubyLLM
    # conversation produced. Both are the glue a host that drives RubyLLM
    # chats would otherwise write itself.
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
    #     ).call.tap(&:verdict) # the verdict is a judge call too: settle it while the run is open
    #   end
    module RubyLLM
      # How much of a tool's error a replay keeps, in bytes — the cap the
      # dashboard puts on a run's tool event detail.
      DETAIL_LIMIT = 1_200

      # `chat` keywords the judge sets itself, so they are not `chat_options`.
      JUDGE_CHAT_KEYWORDS = %i[model provider assume_model_exists context].freeze

      # An `error` key holding a String, as Ruby inspects it: RubyLLM 1.x
      # keeps a tool result's `to_s`, so a tool that returned
      # `{ error: "..." }` stores `{:error=>"..."}`, or `{error: "..."}` on
      # Ruby 3.4. Tried only at the top level of a whole inspected Hash.
      INSPECTED_ERROR_KEY = /\G\s*(?::error\s*=>|error:|"error"\s*=>)\s*("(?:[^"\\]|\\.)*")/m

      class << self
        # Builds a Judge whose completions come from a RubyLLM chat.
        #
        # `context` is anything answering to `#chat` the way RubyLLM does: the
        # `::RubyLLM` module itself, or a `RubyLLM.context` built with the
        # host's own keys (see `ActionAgent::ProviderKey.apply_to`). With a
        # `correlation`, every call is traced through `Correlation#judge` under
        # the kind it serves (`score`, `recommend`, `verdict`), so the judge
        # trace lands on the result it graded.
        #
        # `chat_options` go to `chat` itself, so they must be keywords
        # `RubyLLM::Chat.new` takes (`protocol:` on RubyLLM 2.x); anything else
        # raises ArgumentError here rather than failing every judge call
        # later. Configure the chat through `temperature:` or `configure:`:
        #
        #   ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "gpt-5-mini", provider: :openai,
        #                                     temperature: 0,
        #                                     configure: ->(chat) { chat.with_headers("X-Request-Tag" => "eval") })
        #
        # @param label [String] how reports name the judge
        # @param model [String] the judge model
        # @param provider [Symbol, String] the RubyLLM provider serving it
        # @param context [#chat] where `chat` is called; defaults to `::RubyLLM`
        # @param correlation [Correlation, nil] traces each call as a judge call
        # @param assume_model_exists [Boolean] skip RubyLLM's model registry check
        # @param temperature [Numeric, nil] applied with `with_temperature`
        # @param configure [#call, nil] called with each chat before it is asked,
        #   for any other `with_*` setting
        # @param on_usage [#call, nil] called after each answered call with
        #   `{ "kind", "model", "input_tokens", "output_tokens", "cost" }`, for a
        #   host that meters its judge's spend; an error it raises is logged,
        #   not propagated, so bookkeeping never costs a grade
        # @param chat_options [Hash] other `chat` keywords, such as `protocol:`
        # @return [Judge]
        # @raise [ArgumentError] when `chat_options` names a keyword `RubyLLM::Chat.new` does not take
        def judge(label:, model:, provider:, context: ::RubyLLM, correlation: nil, assume_model_exists: true,
                  temperature: nil, configure: nil, on_usage: nil, **chat_options)
          check_chat_options!(chat_options)

          Judge.new(label: label) do |instructions:, prompt:, kind:|
            complete = lambda do
              chat = context.chat(model: model, provider: provider.to_sym, assume_model_exists: assume_model_exists,
                                  **chat_options)
              chat.with_temperature(temperature) unless temperature.nil?
              configure&.call(chat)
              response = chat.with_instructions(instructions).ask(prompt)
              report_usage(on_usage, kind, model, response)
              response.content
            end

            correlation ? correlation.judge(kind.to_s, &complete) : complete.call
          end
        end

        # Builds a Replay from the ordered messages of a RubyLLM conversation:
        # `acts_as_chat` message records of either RubyLLM generation (read
        # through their own `to_llm`), `RubyLLM::Message` values, or anything
        # shaped like them (`role`, `content`, `tool_calls`, `tool_call_id`,
        # and `tokens` or `input_tokens`/`output_tokens`).
        #
        # - **Tool calls** are every message's calls in the order the model made
        #   them, each `{ "name", "arguments", "error", "detail" }`. A call is
        #   errored when the `tool` message answering it (the next one with its
        #   `tool_call_id`) reports an error at its top level: JSON or a Hash
        #   whose `"error"` is a non-empty String, Hash or Array, or `true`; an
        #   MCP result with `"isError": true`; or the inspected Hash RubyLLM 1.x
        #   stores for a tool that returned `{ error: "..." }`. `detail` is the
        #   error, JSON-encoded unless it is a String, cut to DETAIL_LIMIT bytes.
        # - **Tokens** sum the assistant messages. `input_tokens` is the whole
        #   prompt: RubyLLM's `input` plus its cache reads and writes, which it
        #   counts apart.
        # - **Cost** sums each assistant message's RubyLLM `cost.total` when
        #   every one of them is priced, and is nil otherwise.
        # - **The answer** is the content of the last assistant message after the
        #   last user message. A conversation that stopped before answering —
        #   its last message is a tool call, a tool result or the user's own
        #   message — has no answer, and the replay records why as its error
        #   rather than scoring an empty or earlier reply. On RubyLLM 1.x a tool
        #   that ends the turn with `halt` leaves its result last too: pass the
        #   content `ask` returned as `answer:` for such scenarios.
        #
        # `answer:`, `error:` and `cost:` override what the messages say.
        #
        # @param messages [Array, #to_a] the conversation's messages, oldest first
        # @param answer [String, nil] overrides the last assistant message's content
        # @param duration_ms [Numeric, nil]
        # @param error [String, Exception, nil] when the run raised before answering
        # @param cost [Numeric, nil] overrides the cost RubyLLM priced
        # @param metadata [Hash] carried onto the Result
        # @return [Replay]
        def replay(messages, answer: nil, duration_ms: nil, error: nil, cost: nil, metadata: {})
          messages = messages.to_a.map { |message| message.respond_to?(:to_llm) ? message.to_llm : message }
          unfinished = unfinished_reason(messages)
          tokens = token_totals(messages)

          Replay.new(
            answer: answer.nil? && unfinished.nil? ? final_answer(messages) : answer,
            tool_calls: extract_tool_calls(messages),
            duration_ms: duration_ms,
            input_tokens: tokens[:input],
            output_tokens: tokens[:output],
            error: replay_error(error, answer, unfinished),
            cost: cost.nil? ? conversation_cost(messages) : cost,
            metadata: metadata
          )
        end

        private

        def check_chat_options!(options)
          return if options.empty?

          parameters = ::RubyLLM::Chat.instance_method(:initialize).parameters
          return if parameters.any? { |type, _| type == :keyrest }

          accepted = parameters.filter_map { |type, name| name if %i[key keyreq].include?(type) } - JUDGE_CHAT_KEYWORDS
          unknown = options.keys.map(&:to_sym) - accepted
          return if unknown.empty?

          raise ArgumentError,
                "RubyLLM::Chat.new (ruby_llm #{::RubyLLM::VERSION}) does not take #{unknown.map(&:inspect).join(', ')}; " \
                "it takes #{accepted.map(&:inspect).join(', ').presence || 'no other keywords'}. " \
                "Pass temperature: to judge, or configure the chat with configure: ->(chat) { chat.with_... }."
        end

        def report_usage(callback, kind, model, response)
          return unless callback

          callback.call(
            "kind" => kind.to_s,
            "model" => response_model(response) || model.to_s,
            "input_tokens" => prompt_tokens(response),
            "output_tokens" => token_count(response, :output),
            "cost" => message_cost(response)
          )
        rescue StandardError => e
          warn_failure("judge on_usage callback failed: #{e.class}")
        end

        def response_model(response)
          model = response.model if response.respond_to?(:model)
          model = response.model_id if model.nil? && response.respond_to?(:model_id)
          model.presence&.to_s
        end

        # Each result is paired with the call it answers: the latest call with
        # its id that no earlier result has answered, so an id a provider
        # reuses in a later turn is still told apart.
        def extract_tool_calls(messages)
          open_calls = {}

          messages.each_with_object([]) do |message, calls|
            if role_of(message) == "tool"
              call = open_calls.delete(message.tool_call_id) if message.respond_to?(:tool_call_id)
              detail = call && tool_error(message.content)
              call&.merge!("error" => true, "detail" => detail) if detail
            else
              ordered_tool_calls(message).each do |tool_call|
                call = { "name" => tool_call.name.to_s, "arguments" => tool_call.arguments, "error" => false }
                open_calls[tool_call.id] = call
                calls << call
              end
            end
          end
        end

        # A message's calls in the order the model made them. RubyLLM keys a
        # message's calls by the provider's call id in the order they arrived,
        # and those ids (`call_…`, `toolu_…`) say nothing about order; only
        # record primary keys, which are all Integers, are sorted.
        def ordered_tool_calls(message)
          calls = tool_calls_of(message)
          calls.all? { |call| call.id.is_a?(Integer) } ? calls.sort_by(&:id) : calls
        end

        # `tool_calls` is a Hash keyed by call id on a RubyLLM::Message (and on
        # anything `to_llm` returns), a has_many elsewhere, and nil on a
        # message with no calls.
        def tool_calls_of(message)
          return [] unless message.respond_to?(:tool_calls)

          calls = message.tool_calls
          calls = calls.values if calls.is_a?(Hash)
          calls.nil? ? [] : calls.to_a
        end

        # The detail of the error a tool reported, or nil when it succeeded.
        def tool_error(content)
          content = content.text if !content.is_a?(String) && content.respond_to?(:text)
          content = content.scrub if content.is_a?(String)
          payload = content.is_a?(Hash) ? content : parse_json(content)
          return error_from_payload(payload) if payload.is_a?(Hash)
          return unless content.is_a?(String)

          literal = inspected_error(content.strip)
          truncate_detail(unquote(literal)) if literal
        end

        def error_from_payload(payload)
          error = payload.key?("error") ? payload["error"] : payload[:error]
          if (error.is_a?(String) || error.is_a?(Hash) || error.is_a?(Array)) && error.present?
            return truncate_detail(error.is_a?(String) ? error : error.to_json)
          end
          if error == true
            message = payload["message"] || payload[:message]
            return truncate_detail(message.is_a?(String) && message.present? ? message : payload.to_json)
          end
          return unless (payload["isError"] || payload[:isError]) == true

          texts = Array(payload["content"] || payload[:content]).filter_map do |part|
            part["text"] || part[:text] if part.is_a?(Hash)
          end
          truncate_detail(texts.any? ? texts.join("\n") : payload.to_json)
        end

        # The String literal an inspected Hash holds under a top-level `error`
        # key, or nil. Only a whole Hash (`{...}`) qualifies, and a key is
        # tried only where one starts at the Hash's own level: after its
        # opening brace or a comma outside any string or nested structure.
        def inspected_error(text)
          return unless text.start_with?("{") && text.end_with?("}")

          depth = 0
          quoted = false
          index = 0
          while index < text.length
            char = text[index]
            if quoted
              index += 1 if char == "\\"
              quoted = false if char == '"'
            elsif char == '"'
              quoted = true
            elsif char == "{" || char == "["
              depth += 1
            elsif char == "}" || char == "]"
              depth -= 1
            end

            if !quoted && depth == 1 && (char == "{" || char == ",")
              literal = text.match(INSPECTED_ERROR_KEY, index + 1)&.[](1)
              return literal if literal
            end
            index += 1
          end
          nil
        end

        # Reads back a Ruby String literal from an inspected Hash. `undump`
        # takes only ASCII, so the characters beyond it are escaped first.
        def unquote(literal)
          literal.gsub(/[^\x00-\x7F]/) { |char| format("\\u{%x}", char.ord) }.undump.force_encoding(Encoding::UTF_8).scrub
        rescue RuntimeError, EncodingError, ArgumentError
          literal[1...-1].scrub
        end

        def truncate_detail(detail)
          detail.to_s.truncate_bytes(DETAIL_LIMIT)
        end

        def token_totals(messages)
          assistants = messages.select { |message| role_of(message) == "assistant" }
          {
            input: assistants.sum { |message| prompt_tokens(message) },
            output: assistants.sum { |message| token_count(message, :output) }
          }
        end

        # The whole prompt: RubyLLM counts cache reads and writes apart from
        # `input` (`cache_read`/`cache_write` on 2.x, `cached`/`cache_creation`
        # on 1.x), so they are added back.
        def prompt_tokens(message)
          tokens = message.tokens if message.respond_to?(:tokens)
          if tokens.respond_to?(:input)
            tokens.input.to_i + first_count(tokens, :cache_read, :cached) + first_count(tokens, :cache_write, :cache_creation)
          else
            token_count(message, :input) + first_count(message, :cached_tokens) + first_count(message, :cache_creation_tokens)
          end
        end

        def token_count(message, direction)
          tokens = message.tokens if message.respond_to?(:tokens)
          return tokens.public_send(direction).to_i if tokens.respond_to?(direction)

          first_count(message, :"#{direction}_tokens")
        end

        def first_count(object, *readers)
          reader = readers.find { |name| object.respond_to?(name) }
          reader ? object.public_send(reader).to_i : 0
        end

        def conversation_cost(messages)
          costs = messages.select { |message| role_of(message) == "assistant" }.map { |message| message_cost(message) }
          costs.sum if costs.any? && costs.none?(&:nil?)
        end

        def message_cost(message)
          return unless message.respond_to?(:cost)

          cost = message.cost
          total = cost.respond_to?(:total) ? cost.total : cost
          total.to_f if total.is_a?(Numeric)
        rescue StandardError
          nil
        end

        # Why the conversation has no answer, or nil when it has one: it
        # stopped at a tool call or a tool's result, or on the user's own
        # message. System messages do not count as the last word.
        def unfinished_reason(messages)
          last = messages.reverse.find { |message| role_of(message) != "system" }
          return if last.nil?

          case role_of(last)
          when "user"
            "The conversation ended on a user message without a reply"
          when "tool", "assistant"
            return if role_of(last) == "assistant" && tool_calls_of(last).none?

            assistant = messages.reverse.find { |message| role_of(message) == "assistant" }
            names = (assistant ? tool_calls_of(assistant) : []).map { |call| call.name.to_s }.uniq
            "The conversation stopped at #{names.any? ? "a call to #{names.join(', ')}" : 'a tool result'} " \
              "without a final answer"
          end
        end

        def replay_error(error, answer, unfinished)
          return "#{error.class}: #{error.message}" if error.is_a?(Exception)
          return error unless error.nil?

          unfinished if answer.nil?
        end

        # The last assistant message after the last user message, so an
        # earlier turn's reply never stands in for this one.
        def final_answer(messages)
          last_prompt = messages.rindex { |message| role_of(message) == "user" }
          turn = last_prompt ? messages.drop(last_prompt + 1) : messages
          content = turn.reverse.find { |message| role_of(message) == "assistant" }&.content
          content = content.text if !content.nil? && !content.is_a?(String) && content.respond_to?(:text)
          content
        end

        def role_of(message)
          message.role.to_s
        end

        def parse_json(content)
          return nil unless content.is_a?(String) && content.present?

          JSON.parse(content)
        rescue JSON::ParserError
          nil
        end

        def warn_failure(message)
          message = "[ActiveAgent::Evals] #{message}"
          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.warn(message)
          else
            warn(message)
          end
        end
      end
    end
  end
end
