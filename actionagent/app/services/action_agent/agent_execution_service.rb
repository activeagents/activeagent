# frozen_string_literal: true

module ActionAgent
  # Executes a dashboard-configured Agent through the activeagent gem and
  # records a telemetry trace for the run.
  #
  # The requested provider is used when credentials are available — the
  # account's own provider key (Settings -> Provider API Keys) when configured,
  # else the platform keys in config/active_agent.yml. Without credentials the
  # run fails with an actionable error: execution never falls back to mock
  # output, so every stored run, trace and generation reflects a real provider
  # response. (The gem's mock provider is a test double, accepted only in the
  # test environment.)
  #
  # Traces are built with the gem's ActiveAgent::Telemetry::Span and persisted
  # through TelemetryTrace.create_from_payload — the same normalizer used by
  # the telemetry ingest endpoint — so platform-executed runs and SDK-reported
  # runs share one pipeline.
  class AgentExecutionService
    # Raised when the requested provider has no usable credentials. The run is
    # marked failed with this message — never silently degraded to mock output.
    class ProviderNotConfiguredError < StandardError; end

    SERVICE_NAME = "activeagents-platform"

    def self.call(agent_record, run)
      new(agent_record, run).call
    end

    def initialize(agent_record, run)
      @agent_record = agent_record
      @run = run
      @tool_invocations = []
      @event_sequence = 0
    end

    # Emits a progress event on the run (streamed to the UI by pollers).
    # Never lets telemetry break execution.
    def emit_event(**kwargs)
      @run.append_event(**kwargs)
    rescue StandardError => e
      Rails.logger.warn("[AgentExecutionService] event emit failed: #{e.message}")
    end

    def next_event_id
      @event_sequence += 1
      "#{@run.id}-#{@event_sequence}"
    end

    # Compact human preview of a tool result for the live activity feed:
    # prefer the long readable field (page text, sub-agent output) over JSON.
    def event_result_preview(result)
      return nil unless result.respond_to?(:[])

      readable = %i[text output content body].filter_map { |field| result[field] || result[field.to_s] }
        .find { |value| value.is_a?(String) && value.strip.present? }
      preview = readable ? readable.gsub(/\s+/, " ").strip : result.to_json
      preview.byteslice(0, 1000).to_s.scrub
    end

    def call
      root_span = @root_span = build_root_span
      record_prompt_span(root_span)
      llm_span = root_span.add_span(
        "llm.generate",
        span_type: :llm,
        "llm.provider" => provider.to_s,
        "llm.model" => model
      )

      llm_eid = next_event_id
      llm_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      emit_event(eid: llm_eid, kind: "llm", label: "#{provider}/#{model} generating", status: "started")

      begin
        response = generate!
        usage = response.usage
        input = usage&.input_tokens.to_i
        output = usage&.output_tokens.to_i
        thinking = usage&.reasoning_tokens.to_i

        llm_span.set_tokens(input: input, output: output, thinking: thinking)
        llm_span.finish
        emit_event(
          eid: llm_eid, kind: "llm", label: "#{provider}/#{model} generating", status: "done",
          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - llm_started) * 1000).round,
          detail: "#{input} in / #{output} out tokens#{thinking.positive? ? " / #{thinking} thinking" : ""}"
        )
        tool_calls = record_tool_spans(root_span, response)
        persist_tool_messages(response)
        sync_context_instructions
        root_span.finish

        {
          output: response.message&.content,
          metadata: {
            provider: provider.to_s,
            model: model,
            action: action_name,
            instructions: composed_instructions,
            requested_provider: @agent_record.provider,
            trace_id: root_span.trace_id,
            context_id: conversation_context&.id,
            tool_calls: tool_calls
          },
          usage: {
            input_tokens: input,
            output_tokens: output,
            total_tokens: usage&.total_tokens || input + output + thinking
          }
        }
      rescue StandardError => e
        llm_span.record_error(e)
        llm_span.finish
        root_span.record_error(e)
        root_span.finish
        emit_event(eid: llm_eid, kind: "llm", label: "#{provider}/#{model} generating", status: "error", detail: e.message)
        raise
      ensure
        record_trace(root_span)
      end
    end

    # The outbound prompt as a span, in the SDK's attribute shape — gives the
    # Traces UI its System/User conversation rows and lets the context-pressure
    # meter attribute instructions and tool schemas instead of lumping the
    # whole input into "messages".
    def record_prompt_span(root_span)
      span = root_span.add_span("agent.prompt", span_type: :prompt)
      if composed_instructions.present?
        span.set_attribute("prompt.input.instructions", composed_instructions.to_s.byteslice(0, 6000).to_s.scrub)
      end
      if tool_schemas.present?
        span.set_attribute("prompt.input.tools", tool_schemas.to_json.byteslice(0, 6000).to_s.scrub)
      end
      span.set_attribute(
        "prompt.input.messages",
        [ { role: "user", content: @run.input_prompt.to_s.byteslice(0, 4000).to_s.scrub } ].to_json
      )
      span.set_attribute("messages.count", 1)
      span.finish
    rescue StandardError => e
      Rails.logger.warn("[AgentExecutionService] prompt span failed: #{e.message}")
    end

    # Per-run provider/model overrides (input_params) let callers replay the
    # same agent under a different model — the basis of evaluation comparison
    # runs. Absent overrides, the agent's own configuration applies.
    def run_params
      @run_params ||= (@run.input_params || {}).with_indifferent_access
    end

    def requested_provider
      @requested_provider ||= (run_params[:provider_override].presence || @agent_record.provider).to_s
    end

    def requested_model
      @requested_model ||= run_params[:model_override].presence || @agent_record.model
    end

    # Returns the provider used for this execution, or raises when its
    # credentials are missing.
    def provider
      @provider ||= begin
        unless provider_available?(requested_provider)
          raise ProviderNotConfiguredError,
            "No credentials configured for provider '#{requested_provider}' — " \
            "add an API key in Settings -> Provider API Keys, or configure platform credentials"
        end
        requested_provider.to_sym
      end
    end

    # The named action this run invokes (falls back to the default). Named
    # actions execute under composed instructions: base + the action's prompt.
    def action_name
      @action_name ||= begin
        requested = @run.action_name.presence || Agent::DEFAULT_ACTION
        @agent_record.available_actions.include?(requested) ? requested : Agent::DEFAULT_ACTION
      end
    end

    def composed_instructions
      @composed_instructions ||= @agent_record.composed_instructions_for(action_name)
    end

    # Routes a provider tool call to its implementation: memory tools bind to
    # the agent record's AgentMemory (the solid_agent HasMemory contract);
    # everything else is stateless and lives in AgentToolbox.
    #
    # Each call is wrapped in a live :tool span (real start/end around the
    # execution) and recorded in @tool_invocations so tool names, arguments
    # and durations reach Traces and the persisted conversation.
    def execute_tool(name, **kwargs)
      # Record the absolute URL browse_page will actually fetch, not the bare
      # path the model passed — spans/events/persisted args stay unambiguous.
      kwargs[:url] = AgentToolbox.resolve_browse_url(kwargs[:url]) if name.to_s == "browse_page" && kwargs[:url]

      span = @root_span&.add_span("tool.#{name}", span_type: :tool)
      span&.set_attribute("tool.name", name.to_s)
      # tool.input.args is the key the Traces UI and TraceInteractionSerializer
      # read — the call's in: side.
      span&.set_attribute("tool.input.args", kwargs.to_json.byteslice(0, 500).to_s.scrub) if kwargs.present?
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      event_kind = name.to_s == "call_agent" ? "agent" : "tool"
      event_label = name.to_s == "call_agent" ? "call_agent → #{kwargs[:slug]}" : name.to_s
      event_id = next_event_id
      emit_event(eid: event_id, kind: event_kind, label: event_label, status: "started", detail: kwargs.to_json)

      result = begin
        case name.to_s
        when "save_memory"
          entry = agent_memory.remember(
            kwargs[:content].to_s,
            source_agent: agent_class_name,
            category: kwargs[:category]
          )
          { saved: true, id: entry.id, content: entry.content }
        when "recall_memory"
          entries = agent_memory.recall(limit: kwargs[:limit], category: kwargs[:category])
          {
            count: entries.size,
            entries: entries.map do |entry|
              {
                content: entry.content,
                category: entry.category,
                source_agent: entry.source_agent,
                created_at: entry.created_at&.iso8601
              }.compact
            end
          }
        when "call_agent"
          call_agent(slug: kwargs[:slug], message: kwargs[:message])
        else
          AgentToolbox.call(name, **kwargs)
        end
      rescue StandardError => e
        Rails.logger.warn("[AgentExecutionService] Tool #{name} failed: #{e.class} - #{e.message}")
        { error: "#{name} failed: #{e.message}" }
      end

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2)
      errored = result.respond_to?(:key?) && (result.key?(:error) || result.key?("error"))
      span&.set_attribute("tool.error", true) if errored
      # Record the readable side of the result (most tools wrap one long text
      # field); byteslicing whole-JSON breaks it mid-string and the UI can't
      # parse the remainder.
      result_text =
        if result.respond_to?(:key?) && (result[:text] || result["text"]).is_a?(String)
          result[:text] || result["text"]
        else
          result.to_json
        end
      span&.set_attribute("tool.output.result", result_text.byteslice(0, 4000).to_s.scrub)
      span&.finish
      emit_event(
        eid: event_id, kind: event_kind, label: event_label,
        status: errored ? "error" : "done", duration_ms: duration_ms,
        detail: errored ? (result[:error] || result["error"]).to_s : event_result_preview(result)
      )
      @tool_invocations << {
        name: name.to_s,
        arguments: kwargs,
        duration_ms: duration_ms,
        error: errored
      }

      result
    end

    private

    # Maximum agent-to-agent delegation depth for the call_agent tool. A
    # thread-local counter guards it because the sub-agent runs synchronously
    # on the same thread via Agent#test_execute.
    MAX_CALL_DEPTH = 2

    # Executes another agent of the same account synchronously and returns
    # its reply, so agents can delegate to each other as a tool call. The
    # sub-run is a real AgentRun with its own trace.
    def call_agent(slug:, message:)
      depth = Thread.current[:agent_call_depth].to_i
      return { error: "call_agent depth limit (#{MAX_CALL_DEPTH}) reached" } if depth >= MAX_CALL_DEPTH

      target = workspace_agents.where.not(id: @agent_record.id).find_by(slug: slug.to_s)
      return { error: "No agent with slug '#{slug}' in this workspace" } unless target

      Thread.current[:agent_call_depth] = depth + 1
      begin
        sub_run = target.test_execute(message.to_s)
        {
          agent: target.slug,
          run_id: sub_run.id,
          status: sub_run.status,
          output: sub_run.output.presence || sub_run.error_message
        }
      ensure
        Thread.current[:agent_call_depth] = depth
      end
    end

    # Keeps the persisted context's instructions current so the Interactions
    # view can render the conversation's system message.
    def sync_context_instructions
      context = conversation_context
      return unless context
      return if context.instructions == composed_instructions

      context.update_column(:instructions, composed_instructions)
    rescue StandardError => e
      Rails.logger.warn("[AgentExecutionService] Failed to sync context instructions: #{e.message}")
    end

    # Agents callable via call_agent: everything the calling agent's owner
    # owns. A single-user install has no owner, so every agent is in scope.
    def workspace_agents
      ActionAgent.agents_for(owner).where.not(status: :archived)
    end

    def agent_memory
      @agent_memory ||= AgentMemory.for(@agent_record)
    end

    def model
      requested_model
    end

    # Newer Anthropic models (Opus 4.7+, Sonnet 5, Fable 5/Mythos 5) reject
    # sampling parameters with a 400 — they are thinking-first models steered
    # by prompting/effort instead.
    SAMPLING_UNSUPPORTED_MODELS = /\Aclaude-(opus-5|opus-4-[78]|sonnet-5|fable-5|mythos-5)/

    def generate!
      effective_provider = provider
      provider_model = requested_model
      model_options = @agent_record.model_config.to_h.symbolize_keys.slice(:temperature, :max_tokens, :top_p)
      model_options.except!(:temperature, :top_p) if provider_model.to_s.match?(SAMPLING_UNSUPPORTED_MODELS)
      # The owner's own credential (API key, or host URL for ollama)
      # overrides the host app's config/active_agent.yml settings.
      model_options.merge!(owner_provider_options(effective_provider))
      klass_name = agent_class_name
      agent_record = @agent_record
      input = @run.input_prompt
      instructions = composed_instructions
      action = action_name
      run_trace_id = trace_id
      tool_definitions = tool_schemas
      service = self

      agent_class = Class.new(ActiveAgent::Base) do
        # SolidAgent persists contexts under self.class.name; anonymous
        # classes would fail its agent_name presence validation.
        define_singleton_method(:name) { klass_name }

        # Persist the conversation (agent_contexts / agent_messages /
        # agent_generations) via solid_agent. Auto-context is switched off —
        # the context is loaded explicitly in the action below.
        #
        # The keyword that switches it off was renamed (contextable: ->
        # contextual:) between solid_agent 0.1 and 0.2, and the gemspec floor
        # admits both, so it is resolved from the installed method rather than
        # hard-coded: passing the wrong one is an ArgumentError that only
        # surfaces when a run executes.
        #
        # The model classes are named explicitly because solid_agent infers
        # bare "AgentContext"/"AgentMessage"/"AgentGeneration" and resolves
        # them against Object. The engine's models are namespaced, so the
        # inferred names only resolve in a host app that happens to have
        # top-level models of its own.
        include SolidAgent::HasContext
        has_context(
          ActionAgent.solid_agent_auto_context_keyword => false,
          class_name: "ActionAgent::AgentContext",
          message_class: "ActionAgent::AgentMessage",
          generation_class: "ActionAgent::AgentGeneration"
        )

        if effective_provider == :mock
          # Test environment only (see #provider_available?).
          generate_with :mock
        else
          generate_with effective_provider, model: provider_model, **model_options
        end

        # Expose the agent's server-executable tools as public methods so the
        # gem's tools_function can route provider tool calls to them. The
        # service routes each call to AgentToolbox or, for memory tools, to
        # the run's AgentMemory.
        tool_definitions.each do |definition|
          define_method(definition[:name]) do |**kwargs|
            service.execute_tool(definition[:name], **kwargs)
          end
        end

        # One method per invokable action (the default plus each named action
        # prompt) — solid_agent keys the persisted context by action_name, so
        # each action gets its own interaction stream.
        define_method action do
          # Thread the run's telemetry trace_id through prompt_options so
          # SolidAgent's provenance (and AgentContext#record_generation_with_
          # provenance!) can correlate the persisted generation with its trace.
          prompt_options[:trace_id] = run_trace_id
          load_context(contextable: agent_record)

          options = { message: input }
          options[:instructions] = instructions if instructions.present?
          options[:tools] = tool_definitions if tool_definitions.present?
          prompt(**options)
        end
      end

      agent_class.public_send(action).generate_now
    end

    # Function-calling schemas for the agent's enabled tools that have
    # server-side implementations (none for mock runs — the mock provider
    # doesn't do tool calling).
    def tool_schemas
      return [] if provider == :mock

      AgentToolbox.definitions_for(@agent_record.tools)
    end

    # Persists the tool interaction stream to the solid_agent conversation
    # context so the Interactions view shows the full agent <-> tool
    # exchange. Deduped by tool_call_id — newer solid_agent versions persist
    # these from HasContext already, in which case this is a no-op.
    def persist_tool_messages(response)
      context = conversation_context
      return unless context
      return unless response.respond_to?(:messages)

      tool_messages = Array(response.messages).select do |message|
        message.respond_to?(:role) && message.role.to_s == "tool"
      end

      tool_messages.each_with_index do |message, index|
        tool_call_id = message.respond_to?(:tool_call_id) ? message.tool_call_id : nil
        next if tool_call_id.present? && context.messages.exists?(role: "tool", tool_call_id: tool_call_id)

        # Provider tool messages often carry no name (Ollama's don't); fall
        # back to the service's own invocation record, matched by order.
        invocation = @tool_invocations[index]
        name = (message.name if message.respond_to?(:name)).presence || invocation&.dig(:name)

        context.add_tool_message(
          tool_call_id: tool_call_id,
          tool_name: name,
          result: (message.content if message.respond_to?(:content)),
          arguments: invocation&.dig(:arguments),
          duration_ms: invocation&.dig(:duration_ms)
        )
      end
    rescue StandardError => e
      Rails.logger.error("[AgentExecutionService] Failed to persist tool messages: #{e.message}")
    end

    # Tool names for run metadata. Spans are recorded live in execute_tool;
    # the response-message scan only covers calls the provider executed
    # without routing through the service (none today, but cheap insurance).
    def record_tool_spans(root_span, response)
      return @tool_invocations.map { |invocation| invocation[:name] } if @tool_invocations.any?

      messages = response.respond_to?(:messages) ? Array(response.messages) : []
      tool_messages = messages.select { |message| message.respond_to?(:role) && message.role.to_s == "tool" }

      tool_messages.map do |message|
        name = message.respond_to?(:name) && message.name.presence || "unknown"
        tool_span = root_span.add_span("tool.#{name}", span_type: :tool)
        tool_span.set_attribute("tool.name", name)
        if message.respond_to?(:tool_call_id) && message.tool_call_id.present?
          tool_span.set_attribute("tool.id", message.tool_call_id)
        end
        tool_span.finish
        name
      end
    end

    def provider_available?(name)
      # The gem's mock provider is a test double: accepted only in the test
      # environment so app runs can never store fabricated output.
      return Rails.env.test? if name.to_s == "mock"
      return true if owner_provider_options(name).any?

      config = ActiveAgent.configuration[name.to_sym]
      return false unless config.respond_to?(:[])

      if name.to_s == "ollama"
        config[:host].present?
      else
        config[:access_token].present?
      end
    rescue StandardError
      false
    end

    # Credential overrides for +name+: whatever the host app resolves for
    # this owner first, then the dashboard's own stored ProviderKey.
    def owner_provider_options(name)
      @owner_provider_options ||= {}
      @owner_provider_options[name.to_s] ||= begin
        from_host = ActionAgent.provider_credentials(owner, name.to_s)
        from_host.presence || ProviderKey.for_owner(owner).find_by(provider: name.to_s)&.generation_options || {}
      end
    end

    def build_root_span
      ActiveAgent::Telemetry::Span.new(
        "#{agent_class_name}.prompt",
        trace_id: trace_id,
        span_type: :root,
        "agent.class" => agent_class_name,
        "agent.action" => action_name,
        "agent.provider" => provider.to_s,
        "agent.model" => model,
        "service.name" => SERVICE_NAME,
        "service.environment" => Rails.env,
        "telemetry.sdk.name" => "activeagent",
        "telemetry.sdk.version" => ActiveAgent::VERSION
      )
    end

    def agent_class_name
      @agent_record.telemetry_agent_class
    end

    # Reuse the run's trace_id so AgentRun and TelemetryTrace correlate.
    def trace_id
      @trace_id ||= @run.trace_id.presence || SecureRandom.hex(16)
    end

    # The solid_agent conversation context this execution persisted into
    # (one per agent + action on this platform).
    def conversation_context
      AgentContext.find_by(contextable: @agent_record, agent_name: agent_class_name, action_name: action_name)
    end

    # The agent's owner under the configured mode; nil when the install
    # has no owner model at all.
    def owner
      @owner ||= @agent_record.owner
    end

    def record_trace(root_span)
      payload = {
        trace_id: root_span.trace_id,
        service_name: SERVICE_NAME,
        environment: Rails.env,
        timestamp: Time.current.iso8601(6),
        resource_attributes: { "platform.agent_id" => @agent_record.id, "platform.run_id" => @run.id },
        spans: flatten_spans(root_span)
      }.as_json

      sdk_info = {
        name: "activeagent",
        version: ActiveAgent::VERSION,
        language: "ruby",
        runtime_version: RUBY_VERSION
      }.as_json

      trace_model = ActionAgent.trace_model
      tenant = ActionAgent.tenant_for(owner)
      return if trace_model.for_account(tenant).exists?(trace_id: root_span.trace_id)

      trace_model.create_from_payload(payload, sdk_info, account: tenant)
    rescue StandardError => e
      Rails.logger.error("[AgentExecutionService] Failed to record trace #{root_span.trace_id}: #{e.class} - #{e.message}")
      nil
    end

    # Flattens the span hierarchy the same way the gem's Tracer does before
    # reporting (children stripped, parent_span_id links preserved).
    def flatten_spans(span)
      result = [ span.to_h.except(:children) ]
      span.children.each { |child| result.concat(flatten_spans(child)) }
      result
    end
  end
end
