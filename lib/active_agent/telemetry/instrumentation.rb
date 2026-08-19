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

          # Reuse (or mint) the generation's trace id so the telemetry trace
          # shares one id with everything else that reads
          # prompt_options[:trace_id] — the generation request parameters and
          # e.g. solid_agent's persisted generation records. Without this the
          # tracer generates its own id and traces can't be correlated with
          # the records they describe.
          trace_id = nil
          if respond_to?(:prompt_options) && prompt_options.is_a?(Hash)
            trace_id = (prompt_options[:trace_id] ||= SecureRandom.uuid)
          end

          Telemetry.trace("#{self.class.name}.#{action_name}", span_type: :root, **{ trace_id: trace_id }.compact) do |span|
            span.set_attribute("agent.class", self.class.name)
            span.set_attribute("agent.action", action_name.to_s)
            span.set_attribute("agent.provider", provider_name)
            span.set_attribute("agent.model", model_name)

            # Add prompt span, carrying the prompt contents (instructions +
            # outbound messages) so dashboards can show what was sent.
            prompt_span = span.add_span("agent.prompt", span_type: :prompt)
            if (message_stack = prompt_options[:messages]).respond_to?(:size)
              prompt_span.set_attribute("messages.count", message_stack.size)
            end
            # Attribute order is display order in dashboards: the system
            # message first, then the tool roster, then the (often long)
            # message history.
            if prompt_options.is_a?(Hash)
              rendered_instructions = begin
                prompt_view_instructions(prompt_options[:instructions]) if respond_to?(:prompt_view_instructions)
              rescue StandardError
                prompt_options[:instructions].is_a?(String) ? prompt_options[:instructions] : nil
              end
              if rendered_instructions.present?
                prompt_span.set_attribute("prompt.input.instructions", telemetry_truncate(Array(rendered_instructions).join("\n\n")))
              end

              if (tools = prompt_options[:tools]).present?
                roster = Array(tools).filter_map { |tool|
                  next unless tool.is_a?(Hash)

                  name = tool[:name] || tool["name"]
                  description = tool[:description] || tool["description"]
                  parameters = tool[:parameters] || tool["parameters"] || tool[:input_schema] || tool["input_schema"]
                  properties = parameters.is_a?(Hash) ? (parameters[:properties] || parameters["properties"]) : nil
                  {
                    name: name,
                    description: telemetry_truncate(description),
                    parameters: properties.is_a?(Hash) ? properties.keys : []
                  }.compact
                }
                prompt_span.set_attribute("prompt.input.tools", JSON.generate(roster)) if roster.any?
              end

              # prompt_options[:messages] holds the turns a caller passed
              # explicitly. An agent that renders its user turn from the
              # action's template — the idiomatic form, `instructions:` plus
              # `locals:` — has none at this point: the rendering happens
              # later, in prepare_prompt_parameters. Falling back to it means
              # the message the model actually received is on the trace either
              # way, which is what an evaluation scores.
              outbound = prompt_options[:messages]
              outbound = rendered_prompt_messages if outbound.blank?

              if outbound.present?
                serialized = Array(outbound).map { |message|
                  if message.is_a?(Hash)
                    role = message[:role] || message["role"] || "user"
                    content = message[:content] || message["content"]
                    { role: role.to_s, content: telemetry_truncate(content) }
                  elsif message.respond_to?(:content)
                    { role: (message.try(:role) || "user").to_s, content: telemetry_truncate(message.content) }
                  else
                    { role: "user", content: telemetry_truncate(message) }
                  end
                }
                prompt_span.set_attribute("prompt.input.messages", JSON.generate(serialized))
              end
            end
            prompt_span.finish

            # Execute generation with LLM span
            llm_span = span.add_span("llm.generate", span_type: :llm)
            llm_span.set_attribute("llm.provider", provider_name)
            llm_span.set_attribute("llm.model", model_name)

            # Providers run tools through tools_function mid-generation; the
            # wrapped proc (see below) hangs timed tool spans off this span.
            @_telemetry_llm_span = llm_span

            begin
              result = super

              # Record token usage from response
              if result.respond_to?(:usage) && result.usage.present?
                usage = result.usage
                # Usage model uses methods, not hash access
                input_tokens = (usage.input_tokens rescue 0) || 0
                output_tokens = (usage.output_tokens rescue 0) || 0
                reasoning_tokens = (usage.reasoning_tokens rescue 0) || 0

                llm_span.set_tokens(
                  input: input_tokens.to_i,
                  output: output_tokens.to_i,
                  thinking: reasoning_tokens.to_i
                )
                span.set_tokens(
                  input: input_tokens.to_i,
                  output: output_tokens.to_i,
                  thinking: reasoning_tokens.to_i
                )
              end

              # Record tool calls if present
              if result.respond_to?(:tool_calls) && result.tool_calls.present?
                result.tool_calls.each do |tool_call|
                  tool_span = span.add_span("tool.#{tool_call[:name]}", span_type: :tool)
                  tool_span.set_attribute("tool.name", tool_call[:name])
                  tool_span.set_attribute("tool.id", tool_call[:id]) if tool_call[:id]
                  ToolOrigin.annotate(tool_span, tool_call[:name])
                  tool_span.finish
                end
              end

              # The span was tagged with the configured model (often unset →
              # "unknown"); the provider's raw response knows what actually
              # served the request.
              if result.respond_to?(:raw_response) && result.raw_response.is_a?(Hash)
                served_model = result.raw_response["model"] || result.raw_response[:model]
                llm_span.set_attribute("llm.model", served_model.to_s) if served_model.present?
              end

              # Carry the generation contents so dashboards can show what
              # came back, not just how many tokens it cost.
              if result.respond_to?(:message) && result.message.respond_to?(:content) && result.message.content.present?
                llm_span.set_attribute("llm.output.message", telemetry_truncate(result.message.content))
              end
              if result.respond_to?(:finish_reason) && result.finish_reason.present?
                llm_span.set_attribute("llm.finish_reason", result.finish_reason.to_s)
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
            ensure
              @_telemetry_llm_span = nil
            end
          end
        end

        # Providers invoke this proc for every tool call during generation.
        # Wrapping it is what makes tool telemetry real: each call gets a
        # timed span with its arguments and result — the post-hoc
        # result.tool_calls path below never fires on 1.x responses, which
        # don't expose tool calls.
        def tools_function
          base = super
          return base unless Telemetry.enabled?

          agent = self
          proc do |tool_name, *args, **kwargs|
            parent = agent.instance_variable_get(:@_telemetry_llm_span)
            unless parent
              next base.call(tool_name, *args, **kwargs)
            end

            tool_span = parent.add_span("tool.#{tool_name}", span_type: :tool)
            tool_span.set_attribute("tool.name", tool_name.to_s)
            # Records which MCP server (if any) serves this tool, so tool
            # traffic can be grouped by service downstream.
            ToolOrigin.annotate(tool_span, tool_name)
            arguments = kwargs.presence || (args.length == 1 ? args.first : args.presence)
            if arguments.present?
              tool_span.set_attribute("tool.input.args", agent.send(:telemetry_truncate, JSON.generate(arguments)))
            end
            begin
              result = base.call(tool_name, *args, **kwargs)
              tool_span.set_attribute("tool.output.result", agent.send(:telemetry_truncate, result))
              tool_span.set_status(:ok)
              result
            rescue StandardError => e
              tool_span.record_error(e)
              raise
            ensure
              tool_span.finish
            end
          end
        end

        # Wraps process_embed with telemetry tracing.
        def process_embed
          return super unless Telemetry.enabled?

          Telemetry.trace("#{self.class.name}.embed", span_type: :embedding) do |span|
            span.set_attribute("agent.class", self.class.name)
            span.set_attribute("agent.action", "embed")
            span.set_attribute("agent.provider", provider_name)

            begin
              result = super

              if result.respond_to?(:usage) && result.usage.present?
                usage = result.usage
                input_tokens = (usage.input_tokens rescue 0) || 0
                span.set_tokens(input: input_tokens.to_i)
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

        # Content attributes are capped so a large prompt (e.g. a 100k-token
        # tool loop) can't bloat the trace payload.
        TELEMETRY_ATTRIBUTE_MAX_CHARS = 4_000

        # The turns this generation will actually send, for an agent that
        # renders its user message from the action's template rather than
        # passing `messages:`. prepare_prompt_parameters is a pure function of
        # prompt_options — it deep_dups its input and mutates no instance
        # state — so calling it here is a read, not a side effect. It does
        # re-render the templates, which is why it is only reached when there
        # are no explicit messages to record.
        #
        # Never raises: a provider that builds parameters differently, or an
        # agent whose templates need context this call does not have, must
        # cost the generation nothing more than an absent attribute.
        def rendered_prompt_messages
          return unless respond_to?(:prepare_prompt_parameters, true)

          parameters = prepare_prompt_parameters
          parameters[:messages] || parameters["messages"]
        rescue StandardError => e
          logger&.debug { "[ActiveAgent::Telemetry] could not read rendered messages: #{e.class}: #{e.message}" }
          nil
        end

        def telemetry_truncate(value)
          text = value.to_s
          return text if text.length <= TELEMETRY_ATTRIBUTE_MAX_CHARS

          "#{text[0, TELEMETRY_ATTRIBUTE_MAX_CHARS]}… (truncated, #{text.length} chars total)"
        end

        def provider_name
          klass = prompt_provider_klass
          klass.respond_to?(:tag_name) ? klass.tag_name : "unknown"
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
