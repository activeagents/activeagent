# frozen_string_literal: true

require "timeout"

module ActiveAgent
  module Delegation
    # Executes one delegated call: budget check, sub-agent generation, result
    # validation, accounting.
    #
    # The runner is what makes a sub-agent a *tool* rather than a method call.
    # It answers to the calling model in the model's own terms — a refused call
    # comes back as a structured result the model can reason about, not as an
    # exception that ends the conversation.
    #
    # @api private
    class Runner
      # @return [Definition]
      attr_reader :definition
      # @return [ActiveAgent::Base] the delegating agent instance
      attr_reader :owner

      # @param definition [Definition]
      # @param owner [ActiveAgent::Base]
      def initialize(definition, owner:)
        @definition = definition
        @owner      = owner
      end

      # Runs the delegated call.
      #
      # @param arguments [Hash] arguments supplied by the calling model
      # @return [Object] the sub-agent's result, or a structured error the
      #   calling model can act on
      # @raise [BudgetExceededError] when the budget policy is +:raise+
      # @raise [InvalidResultError] when the returns policy is +:raise+
      def call(**arguments)
        if (violation = budget_violation)
          return refuse(violation)
        end

        arguments = coerce_arguments(arguments)

        instrument(arguments) do |payload|
          started  = clock
          response = nil

          begin
            response = with_timeout { generate(arguments) }
          rescue Timeout::Error
            duration = clock - started
            record(duration: duration)
            payload[:status]      = :timed_out
            payload[:duration_ms] = (duration * 1_000).round

            next timed_out(duration)
          end

          duration = clock - started
          usage    = response.usage
          model    = response.model.presence || generation_model(response)
          cost     = Pricing.cost_for(usage: usage, model: model, rates: budget.rates)

          record(tokens: usage&.total_tokens, cost: cost, duration: duration)

          payload[:status]      = :ok
          payload[:model]       = model
          payload[:duration_ms] = (duration * 1_000).round
          payload[:usage]       = usage
          payload[:cost]        = cost
          payload[:ledger]      = ledgers.last.to_h

          result(response, payload)
        end
      end

      private

      # @return [Budget]
      def budget = definition.budget

      # Agent-wide ledger first, then this delegation's own — a call has to
      # clear both.
      #
      # @return [Array<Ledger>]
      def ledgers
        @ledgers ||= [ owner.delegation_ledger, owner.delegation_ledger_for(definition.tool_name) ]
      end

      # @return [Budget::Violation, nil]
      def budget_violation
        owner.class.delegation_budget.violation_for(ledgers.first) || budget.violation_for(ledgers.last)
      end

      # @param tokens [Integer, nil]
      # @param cost [Float, nil]
      # @param duration [Float]
      # @return [void]
      def record(tokens: 0, cost: nil, duration: 0.0)
        ledgers.each { |ledger| ledger.record(tokens: tokens, cost: cost, duration: duration) }
      end

      # Drops arguments the contract never declared, so a model that
      # hallucinates an extra key gets a working call instead of an
      # +ArgumentError+ from the sub-agent's method signature.
      #
      # @param arguments [Hash]
      # @return [Hash]
      def coerce_arguments(arguments)
        arguments = arguments.symbolize_keys
        return arguments if definition.schema.empty?

        arguments.slice(*definition.schema.keys)
      end

      # @param arguments [Hash]
      # @return [ActiveAgent::Providers::Common::PromptResponse]
      def generate(arguments)
        agent = definition.resolved_agent_class.new
        agent.params = resolved_params(arguments)
        agent.process(definition.action, **arguments)

        definition.backend.apply(agent)
        apply_returns_format(agent)
        inherit_trace_id(agent)

        agent.process_prompt
      end

      # A delegated generation is part of its parent's work, so it carries the
      # parent's trace id — otherwise the sub-agent's tokens and latency land
      # in a separate trace and the budget you set has nothing to show for it.
      #
      # @param agent [ActiveAgent::Base]
      # @return [void]
      def inherit_trace_id(agent)
        trace_id = owner.prompt_options[:trace_id]
        agent.prompt_options[:trace_id] ||= trace_id if trace_id
      end

      # A declared +returns+ schema *is* the response format for the delegated
      # call; the sub-agent does not have to restate it.
      #
      # @param agent [ActiveAgent::Base]
      # @return [void]
      def apply_returns_format(agent)
        return unless definition.structured?

        agent.prompt_options[:response_format] = {
          type: :json_schema,
          json_schema: definition.returns.to_response_format(name: "#{definition.tool_name}_result")
        }
      end

      # @param arguments [Hash]
      # @return [Hash]
      def resolved_params(arguments)
        case (params = definition.params)
        when nil    then {}
        when Hash   then params
        when Symbol then owner.send(params)
        when Proc   then params.arity == 1 ? owner.instance_exec(arguments, &params) : owner.instance_exec(&params)
        else
          raise ArgumentError, "Delegation params must be a Hash, Symbol or Proc, got #{params.inspect}"
        end.to_h.symbolize_keys
      end

      # @yield the delegated generation
      # @return [Object]
      def with_timeout
        return yield unless budget.timeout

        Timeout.timeout(budget.timeout) { yield }
      end

      # @param response [ActiveAgent::Providers::Common::PromptResponse]
      # @param payload [Hash] instrumentation payload
      # @return [Object]
      def result(response, payload)
        message = response.message
        return nil if message.nil?

        return text_of(message) unless definition.structured?

        parsed  = message.respond_to?(:parsed_json) ? message.parsed_json : nil
        missing = definition.returns.missing_keys(parsed)
        return parsed if missing.empty?

        payload[:status]  = :invalid_result
        payload[:missing] = missing

        invalid(missing, text_of(message))
      end

      # @param message [Object]
      # @return [String]
      def text_of(message)
        message.respond_to?(:text) ? message.text : message.content.to_s
      end

      # @param response [ActiveAgent::Providers::Common::PromptResponse]
      # @return [String, nil]
      def generation_model(response)
        response.context.is_a?(Hash) ? response.context[:model] : nil
      end

      # @param violation [Budget::Violation]
      # @return [Hash]
      def refuse(violation)
        ActiveSupport::Notifications.instrument("delegation_refused.active_agent", instrument_payload.merge(
          status: :budget_exceeded, limit: violation.limit, allowed: violation.allowed, used: violation.used
        ))

        if budget.policy == :raise
          raise BudgetExceededError.new(violation, definition: definition)
        end

        { error: "budget_exceeded", limit: violation.limit.to_s, allowed: violation.allowed, used: violation.used, message: violation.message }
      end

      # @param duration [Float]
      # @return [Hash]
      def timed_out(duration)
        if budget.policy == :raise
          raise TimeoutError, "#{definition.agent_class}##{definition.action} exceeded its #{budget.timeout}s delegation timeout"
        end

        {
          error: "timeout",
          limit: "timeout",
          allowed: budget.timeout,
          used: duration.round(3),
          message: "The #{definition.tool_name} delegation timed out after #{budget.timeout}s. " \
                   "Answer with the information you already have, or call it with a smaller request."
        }
      end

      # @param missing [Array<Symbol>]
      # @param content [String]
      # @return [Hash]
      def invalid(missing, content)
        if definition.on_invalid == :raise
          raise InvalidResultError, "#{definition.agent_class}##{definition.action} returned a result missing " \
            "required #{"key".pluralize(missing.size)}: #{missing.join(", ")}"
        end

        {
          error: "invalid_result",
          missing: missing.map(&:to_s),
          message: "The #{definition.tool_name} delegation returned a result missing required " \
                   "#{"key".pluralize(missing.size)}: #{missing.join(", ")}.",
          content: content
        }
      end

      # @param arguments [Hash]
      # @yield [Hash] instrumentation payload
      def instrument(arguments, &block)
        ActiveSupport::Notifications.instrument(
          "delegate.active_agent", instrument_payload.merge(arguments: arguments), &block
        )
      end

      # @return [Hash]
      def instrument_payload
        {
          agent: owner.class.name,
          delegate: definition.agent_class.name,
          action: definition.action,
          tool: definition.tool_name.to_s,
          provider: definition.backend.provider,
          budget: budget.to_h.except(:rates)
        }.compact
      end

      # Monotonic so a clock adjustment mid-generation can't corrupt a latency budget.
      #
      # @return [Float]
      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
