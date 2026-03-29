# frozen_string_literal: true

module ActiveAgent
  module Telemetry
    # Auto-instrumentation for ActiveAgent generation lifecycle.
    #
    # When included in ActiveAgent::Base, automatically traces:
    # - Agent generation (prompt_now, generate_now)
    # - Tool calls
    # - Streaming events
    # - Errors
    #
    # @example Enabling instrumentation
    #   # In config/initializers/activeagent.rb
    #   ActiveAgent::Telemetry.configure do |config|
    #     config.enabled = true
    #     config.endpoint = "https://api.activeagents.ai/v1/traces"
    #     config.api_key = Rails.application.credentials.activeagents_api_key
    #   end
    #
    #   # Instrumentation is automatically applied when telemetry is enabled
    #
    module Instrumentation
      extend ActiveSupport::Concern

      included do
        # Hook into generation lifecycle
        around_generate :trace_generation if respond_to?(:around_generate)
      end

      class_methods do
        # Installs instrumentation on the agent class.
        #
        # Called automatically when telemetry is enabled.
        def instrument_telemetry!
          return if @telemetry_instrumented

          prepend GenerationInstrumentation
          @telemetry_instrumented = true
        end
      end

      # Module prepended to intercept generation methods.
      module GenerationInstrumentation
        # Wraps process_prompt with telemetry tracing.
        def process_prompt
          return super unless Telemetry.enabled?

          Telemetry.trace("#{self.class.name}.#{action_name}", span_type: :root) do |span|
            span.set_attribute("agent.class", self.class.name)
            span.set_attribute("agent.action", action_name.to_s)
            span.set_attribute("agent.provider", provider_name) if respond_to?(:provider_name)
            span.set_attribute("agent.model", model_name) if respond_to?(:model_name)

            # Add prompt span
            prompt_span = span.add_span("agent.prompt", span_type: :prompt)
            prompt_span.set_attribute("messages.count", messages.size) if respond_to?(:messages)
            prompt_span.finish

            # Execute generation with LLM span
            llm_span = span.add_span("llm.generate", span_type: :llm)
            llm_span.set_attribute("llm.provider", provider_name) if respond_to?(:provider_name)
            llm_span.set_attribute("llm.model", model_name) if respond_to?(:model_name)

            begin
              result = super

              # Record token usage from response
              if result.respond_to?(:usage)
                usage = result.usage
                llm_span.set_tokens(
                  input: usage[:input_tokens] || usage["input_tokens"] || 0,
                  output: usage[:output_tokens] || usage["output_tokens"] || 0,
                  thinking: usage[:thinking_tokens] || usage["thinking_tokens"] || 0
                )
                span.set_tokens(
                  input: usage[:input_tokens] || usage["input_tokens"] || 0,
                  output: usage[:output_tokens] || usage["output_tokens"] || 0,
                  thinking: usage[:thinking_tokens] || usage["thinking_tokens"] || 0
                )
              end

              # Record tool calls if present
              if result.respond_to?(:tool_calls) && result.tool_calls.present?
                result.tool_calls.each do |tool_call|
                  tool_span = span.add_span("tool.#{tool_call[:name]}", span_type: :tool)
                  tool_span.set_attribute("tool.name", tool_call[:name])
                  tool_span.set_attribute("tool.id", tool_call[:id]) if tool_call[:id]
                  tool_span.finish
                end
              end

              llm_span.set_status(:ok)
              llm_span.finish
              span.set_status(:ok)

              result
            rescue StandardError => e
              llm_span.record_error(e)
              llm_span.finish
              span.record_error(e)
              raise
            end
          end
        end

        # Wraps process_embed with telemetry tracing.
        def process_embed
          return super unless Telemetry.enabled?

          Telemetry.trace("#{self.class.name}.embed", span_type: :embedding) do |span|
            span.set_attribute("agent.class", self.class.name)
            span.set_attribute("agent.action", "embed")
            span.set_attribute("agent.provider", provider_name) if respond_to?(:provider_name)

            begin
              result = super

              if result.respond_to?(:usage)
                usage = result.usage
                span.set_tokens(input: usage[:input_tokens] || usage["input_tokens"] || 0)
              end

              span.set_status(:ok)
              result
            rescue StandardError => e
              span.record_error(e)
              raise
            end
          end
        end

        private

        def provider_name
          self.class.generation_provider&.to_s || "unknown"
        rescue StandardError
          "unknown"
        end

        def model_name
          prompt_options[:model] || "unknown"
        rescue StandardError
          "unknown"
        end
      end
    end
  end
end
