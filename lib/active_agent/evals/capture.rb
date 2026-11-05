# frozen_string_literal: true

module ActiveAgent
  module Evals
    # Runs one agent generation and records what the agent did, as a Replay:
    # the answer, every tool it called (arguments, result or error, timing),
    # how long the generation took and the tokens it used. It is the glue
    # between `MyAgent.with(...).action` and the Runner's `replay` callable,
    # and what TestHelper#run_eval returns.
    #
    #   replay = ActiveAgent::Evals::Capture.run(SupportAgent.with(question: "Where is order 4821?").help)
    #   replay.answer       # => "Order 4821 shipped on Monday."
    #   replay.tool_names   # => ["lookup_order"]
    #   replay.tool_calls   # => [{ "name" => "lookup_order", "arguments" => { "number" => "4821" }, ... }]
    #
    # Tool calls are captured on the agent instance's `tools_function`, the
    # proc every provider calls to run a tool, which is also where the
    # telemetry tool spans hang. A tool served by a client-side MCP server
    # (`mcp_strategy: :client`, or a provider with no MCP of its own) is
    # dispatched before that proc, so the provider reports it through the
    # agent's `tool_observer` instead, with a failure the server reported
    # marked as one. A tool a provider runs on its own side (Anthropic's or
    # OpenAI's hosted MCP) never reaches this process and is not recorded.
    #
    # `model:` and `provider:` replay the same action under another model,
    # the way a comparison run does. A model is an option on the agent
    # instance. A provider is a subclass of the agent configured with
    # `generate_with provider, model:`, named as its parent so its templates
    # still resolve; the parent's `instructions:` option is carried, and the
    # rest of its options follow `generate_with`'s own rule for a subclass
    # (kept under the same service, dropped under another).
    #
    # A block runs the agent some other way; it may return a PromptResponse,
    # a Replay, a Hash of Replay attributes, or the answer as a String. Tool
    # calls are then whatever the block reports, since nothing wrapped the
    # agent.
    #
    # An exception becomes an errored Replay, as it does under Runner, so a
    # scenario that raised is scored and diagnosed like any other;
    # `raise_errors: true` re-raises it instead, for the backtrace.
    class Capture
      # How much of a tool's result a tool call keeps as its "detail".
      DETAIL_LIMIT = 500

      # @param generation [ActiveAgent::Generation, nil] the action to run; nil with a block
      # @param model [String, nil] the model to run under instead of the agent's own
      # @param provider [Symbol, String, nil] the provider to run under instead of the agent's own
      # @param metadata [Hash] carried onto the Replay's metadata
      # @param raise_errors [Boolean] re-raise instead of returning an errored Replay
      # @return [Replay]
      def self.run(generation = nil, model: nil, provider: nil, metadata: {}, raise_errors: false, &block)
        new(generation, model: model, provider: provider, metadata: metadata, raise_errors: raise_errors).call(&block)
      end

      def initialize(generation = nil, model: nil, provider: nil, metadata: {}, raise_errors: false)
        @generation = generation
        @model = model
        @provider = provider
        @metadata = (metadata || {}).to_h.transform_keys(&:to_s)
        @raise_errors = raise_errors
        @tool_calls = []
        @agent = nil
      end

      def call(&block)
        raise ArgumentError, "give Capture a generation to run, or a block that runs the agent" unless @generation || block

        started = self.class.monotonic_ms
        value =
          begin
            @generation ? run_generation : block.call
          rescue StandardError => e
            raise if @raise_errors

            return Replay.failed(e, tool_calls: @tool_calls, duration_ms: self.class.elapsed_ms(started), metadata: base_metadata)
          end

        replay_for(value, duration_ms: self.class.elapsed_ms(started))
      end

      # The generation with `model:` and `provider:` applied: the one given
      # when neither is set, otherwise a copy that instantiates the retargeted
      # agent. Public so a host that runs generations itself can retarget the
      # same way.
      def self.retarget(generation, model: nil, provider: nil)
        return generation unless model || provider

        copy = generation.dup
        # The memoized agent, if the generation was already touched, belongs
        # to the original class and action.
        copy.instance_variable_set(:@agent, nil)
        copy.agent_class = provider ? subclass_under(generation.agent_class, provider, model) : generation.agent_class
        copy
      end

      # A subclass of `agent_class` that generates with `provider` (and
      # `model`, when given), named as its parent so `agent_name`, the view
      # prefixes and the telemetry span names stay the parent's.
      def self.subclass_under(agent_class, provider, model)
        parent_name = agent_class.name
        parent_options = agent_class.prompt_options || {}

        Class.new(agent_class).tap do |klass|
          klass.define_singleton_method(:name) { parent_name }
          klass.generate_with(provider, **{ model: model }.compact)
          # generate_with never inherits a parent's instructions. A replay is
          # the same agent under another model, so they come along.
          klass.prompt_options[:instructions] = parent_options[:instructions] if parent_options.key?(:instructions)
        end
      end

      # Runs one tool call and appends its record to +calls+: the name, the
      # arguments, a preview of the result and the time it took. A call that
      # raises is recorded as an error and re-raised. So is one an MCP server
      # reported as failed: it comes back as an MCPBridge::ErrorResult rather
      # than an exception, so the model can recover, and is returned to the
      # provider unchanged.
      #
      # @api private
      # @return [Object] what the call returned
      def self.record_call(calls, name, arguments)
        call = { "name" => name.to_s }
        call["arguments"] = jsonable(arguments) unless arguments.nil?
        started = monotonic_ms

        begin
          result = yield
          if mcp_error?(result)
            call["error"] = true
            call["detail"] = preview(result.message)
          else
            call["detail"] = preview(result)
          end
          result
        rescue StandardError => e
          call["error"] = true
          call["detail"] = "#{e.class}: #{e.message}"
          raise
        ensure
          call["duration_ms"] = elapsed_ms(started)
          calls << call
        end
      end

      def self.mcp_error?(result)
        defined?(ActiveAgent::Providers::MCPBridge::ErrorResult) && result.is_a?(ActiveAgent::Providers::MCPBridge::ErrorResult)
      end
      private_class_method :mcp_error?

      def self.monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      end

      def self.elapsed_ms(started)
        monotonic_ms - started
      end

      # Tool arguments and results as JSON would carry them (string keys,
      # plain values), so a recorded call compares with what a test writes.
      def self.jsonable(value)
        JSON.parse(JSON.generate(value))
      rescue StandardError
        value.to_s
      end

      def self.preview(value)
        text = value.is_a?(String) ? value : (JSON.generate(value) rescue value.to_s)
        text.length > DETAIL_LIMIT ? "#{text[0, DETAIL_LIMIT]}…" : text
      end

      private

      def run_generation
        generation = self.class.retarget(@generation, model: @model, provider: @provider)
        # Generation#agent is private: nothing outside should touch the agent
        # before prompt_later. A capture runs it now, and needs the instance
        # to hook its tool dispatch, so it reaches in on purpose.
        @agent = generation.send(:agent)
        @agent.prompt_options[:model] = @model if @model && !@provider
        record_tool_calls(@agent)
        generation.generate_now
      end

      # Wraps the agent's tools_function so each dispatch lands in
      # @tool_calls. The singleton method takes precedence over the telemetry
      # module prepended on the class, and `base` is that module's wrapped
      # proc, so tool spans still fire.
      #
      # A tool served by a client-side MCP server never reaches tools_function:
      # the provider runs that call inside the agent's `tool_observer`, which
      # records it the same way. The two paths are disjoint, so a call is
      # recorded once, and the observer sees the call without making it again.
      def record_tool_calls(agent)
        calls = @tool_calls
        base = agent.tools_function
        capture = self.class

        agent.define_singleton_method(:tools_function) do
          proc do |name, *args, **kwargs|
            arguments = kwargs.presence || (args.length == 1 ? args.first : args.presence)
            capture.record_call(calls, name, arguments) { base.call(name, *args, **kwargs) }
          end
        end

        agent.define_singleton_method(:tool_observer) do
          proc { |name, arguments, &call| capture.record_call(calls, name, arguments.presence, &call) }
        end
      end

      def replay_for(value, duration_ms:)
        case value
        when Replay
          attributes = value.to_h.transform_keys(&:to_sym).merge(
            tool_calls: value.tool_calls.presence || @tool_calls,
            duration_ms: value.duration_ms || duration_ms,
            metadata: base_metadata.merge(value.metadata)
          )
          Replay.new(**attributes)
        when Hash
          replay_for(Replay.new(**value.to_h.transform_keys(&:to_sym)), duration_ms: duration_ms)
        when String, nil
          Replay.new(answer: value, tool_calls: @tool_calls, duration_ms: duration_ms, metadata: base_metadata)
        else
          unless value.respond_to?(:messages)
            raise ArgumentError, "expected the agent run to return a PromptResponse, a Replay, a Hash or a String, got #{value.class}"
          end

          replay_from_response(value, duration_ms: duration_ms)
        end
      end

      def replay_from_response(response, duration_ms:)
        usage = response.respond_to?(:usage) ? response.usage : nil
        messages = Array(response.messages)

        Replay.new(
          answer: final_answer(messages),
          tool_calls: @tool_calls,
          duration_ms: duration_ms,
          input_tokens: usage&.input_tokens,
          output_tokens: usage&.output_tokens,
          metadata: base_metadata.merge({ "prompt" => user_prompt(messages) }.compact)
        )
      end

      # The agent's last assistant turn. A tool loop leaves tool calls and
      # results before it; the final text comes last.
      def final_answer(messages)
        message = messages.reverse.find { |candidate| candidate.respond_to?(:role) && candidate.role.to_s == "assistant" }
        return nil unless message

        message.respond_to?(:text) ? message.text : message.content.to_s
      end

      # What the user asked, for the scenario a test scores the replay
      # against: the first user turn, when it is plain text.
      def user_prompt(messages)
        message = messages.find { |candidate| candidate.respond_to?(:role) && candidate.role.to_s == "user" }
        content = message&.content
        content if content.is_a?(String) && content.present?
      end

      def base_metadata
        options = @agent&.prompt_options || {}
        {
          "agent" => @agent&.class&.name,
          "action" => @generation&.action_name&.to_s,
          "provider" => @provider&.to_s,
          "service" => options[:service]&.to_s,
          "model" => (@model || options[:model])&.to_s
        }.compact.merge(@metadata)
      end
    end
  end
end
