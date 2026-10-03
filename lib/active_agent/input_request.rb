# frozen_string_literal: true

module ActiveAgent
  # A question a tool puts to the user in the middle of a generation.
  #
  # A tool returns one in place of a result. It is a value, not an exception.
  # The provider leaves that call unanswered, finishes the other calls of the turn,
  # and ends the generation paused: the response is
  # {Providers::Common::Responses::Prompt#awaiting_input? awaiting input},
  # lists the requests, and carries the checkpoint {Generation#resume_now}
  # continues from. On resume the paused call is dispatched again, and the
  # tool reads the user's answer through {.answer_for}.
  #
  # Kinds:
  #   - `:text`    free text
  #   - `:choice`  one of `options`
  #   - `:confirm` approve (`true`) or decline (`false`)
  #   - `:secret`  a value the model must never see, such as a token
  #
  # Answering `false` declines a request of any kind: the tool is not
  # dispatched again and the model reads {DECLINED_RESULT} as its result.
  #
  # `options`, `schema` and `metadata` are stored in their JSON form, so a
  # request survives a round trip through {#to_h} and {.from_h} unchanged.
  #
  # @example A tool that asks before acting
  #   def issue_refund(order_id:, amount:)
  #     unless input_answer
  #       return ActiveAgent::InputRequest.confirm("Refund #{amount} on order #{order_id}?")
  #     end
  #
  #     Refund.create!(order_id:, amount:)
  #   end
  class InputRequest < Data.define(:kind, :prompt, :options, :schema, :tool_call_id, :tool_name, :metadata)
    KINDS = %i[text choice confirm secret].freeze

    # What the model reads for a declined request.
    DECLINED_RESULT = { error: "declined by user" }.freeze

    # Replaces a registered secret wherever {.scrub} finds it.
    FILTERED = "[FILTERED]"

    # Raised by {Generation#resume_now} before any tool runs or any request is
    # sent, when the answers or the checkpoint do not fit the generation.
    class ResumeError < ArgumentError; end

    # Raised when a tool returns an InputRequest under a provider whose tool
    # loop cannot pause.
    class UnsupportedProviderError < NotImplementedError; end

    EXECUTION_STATE_KEY = :active_agent_input_request_tool_call
    private_constant :EXECUTION_STATE_KEY

    class << self
      # @param prompt [String] the question shown to the user
      # @return [InputRequest]
      def text(prompt, **attributes) = new(kind: :text, prompt:, **attributes)

      # @param prompt [String]
      # @param options [Array] the answers to choose from, as values or
      #   `{ value:, label: }` hashes
      # @return [InputRequest]
      def choice(prompt, options:, **attributes) = new(kind: :choice, prompt:, options:, **attributes)

      # @param prompt [String]
      # @return [InputRequest]
      def confirm(prompt, **attributes) = new(kind: :confirm, prompt:, **attributes)

      # @param prompt [String]
      # @return [InputRequest]
      def secret(prompt, **attributes) = new(kind: :secret, prompt:, **attributes)

      # @param hash [Hash] the output of {#to_h}, with string or symbol keys
      # @return [InputRequest]
      def from_h(hash)
        attributes = hash.to_h.symbolize_keys.slice(*members)
        new(**attributes)
      end

      # Returns the answer delivered for a tool call while that call is being
      # dispatched again on resume; nil at any other time.
      #
      # @param tool_call_id [String] the provider's id for the call
      # @return [Object, nil]
      def answer_for(tool_call_id)
        state = ActiveSupport::IsolatedExecutionState[EXECUTION_STATE_KEY]
        state[:answer] if state && state[:id] == tool_call_id.to_s
      end

      # Returns the provider's id for the tool call being dispatched, so a tool
      # can look up its own answer; nil outside a tool call.
      #
      # @return [String, nil]
      def current_tool_call_id
        ActiveSupport::IsolatedExecutionState[EXECUTION_STATE_KEY]&.fetch(:id)
      end

      # Runs a tool call with its id, and its answer when there is one, in
      # execution state. A nil `tool_call_id` runs the block outside any tool
      # call, so it reads no id and no answer. A nested generation inside the
      # call sees its own calls; the outer call's state is restored when the
      # block returns.
      #
      # @param tool_call_id [String, nil]
      # @param answer [Object, nil]
      # @return [Object] the block's result
      # @api private
      def dispatching(tool_call_id, answer: nil)
        previous = ActiveSupport::IsolatedExecutionState[EXECUTION_STATE_KEY]
        ActiveSupport::IsolatedExecutionState[EXECUTION_STATE_KEY] = tool_call_id.nil? ? nil : { id: tool_call_id.to_s, answer: }

        yield
      ensure
        ActiveSupport::IsolatedExecutionState[EXECUTION_STATE_KEY] = previous
      end

      # Returns `value` with every secret replaced by {FILTERED}, in strings at
      # any depth of a Hash or Array. A value of any other class is scrubbed in
      # its JSON form, which is what a tool result becomes on its way to the
      # model. An InputRequest is returned as it is.
      #
      # @param value [Object]
      # @param secrets [Array<String>]
      # @return [Object]
      def scrub(value, secrets)
        secrets = Array(secrets).map(&:to_s).reject(&:empty?).uniq.sort_by { -_1.length }
        return value if secrets.empty?

        scrub_value(value, secrets)
      end

      # Returns `error` itself when its message holds no secret, and otherwise
      # a copy of it with the secrets in the message replaced.
      #
      # @param error [Exception]
      # @param secrets [Array<String>]
      # @return [Exception]
      def scrub_error(error, secrets)
        message = scrub(error.message, secrets)
        message == error.message ? error : error.exception(message)
      end

      private

      def scrub_value(value, secrets)
        case value
        when String
          secrets.reduce(value) { |text, secret| text.gsub(secret, FILTERED) }
        when Hash
          value.to_h { |key, item| [ scrub_value(key, secrets), scrub_value(item, secrets) ] }
        when Array
          value.map { scrub_value(_1, secrets) }
        when InputRequest, Symbol, Numeric, true, false, nil
          value
        else
          scrub_value(value.as_json, secrets)
        end
      end
    end

    # @param kind [Symbol, String] one of {KINDS}
    # @param prompt [String] the question shown to the user
    # @param options [Array, nil] the answers to choose from; required for `:choice`
    # @param schema [Hash, nil] a JSON Schema describing the answer
    # @param tool_call_id [String, nil] set by the provider
    # @param tool_name [String, nil] set by the provider
    # @param metadata [Hash] anything the host wants to keep with the request
    # @raise [ArgumentError] for an unknown kind, a blank prompt, or a choice
    #   without options
    def initialize(kind:, prompt:, options: nil, schema: nil, tool_call_id: nil, tool_name: nil, metadata: {})
      kind = kind.to_s.to_sym
      raise ArgumentError, "Unknown input request kind #{kind.inspect}; expected one of #{KINDS.join(", ")}" unless KINDS.include?(kind)
      raise ArgumentError, "An input request needs a prompt" if prompt.blank?
      raise ArgumentError, "A :choice input request needs options" if kind == :choice && options.blank?

      super(
        kind:,
        prompt: prompt.to_s,
        options: options&.then { Array.wrap(_1).as_json },
        schema: schema&.as_json,
        tool_call_id: tool_call_id&.to_s,
        tool_name: tool_name&.to_s,
        metadata: (metadata || {}).as_json
      )
    end

    # Returns a copy bound to the tool call that returned it.
    #
    # @param id [String]
    # @param name [String]
    # @return [InputRequest]
    # @api private
    def for_tool_call(id:, name:)
      self.class.new(**attributes.merge(tool_call_id: id, tool_name: name))
    end

    # @return [Boolean]
    def secret? = kind == :secret

    # Returns the values a `:choice` answer may take: each option, or its
    # `value` when the option is a hash.
    #
    # @return [Array]
    def choice_values
      Array(options).map { _1.is_a?(Hash) ? _1.fetch("value", _1["label"]) : _1 }
    end

    # @return [Hash{Symbol => Object}] JSON-safe attributes; nil ones are left out
    def to_h = attributes.merge(kind: kind.to_s).compact

    private

    def attributes = self.class.members.to_h { [ _1, public_send(_1) ] }
  end
end

require_relative "input_request/resume"
