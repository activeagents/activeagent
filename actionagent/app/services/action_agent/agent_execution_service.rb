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

    # Images and PDFs above this size are described rather than sent —
    # a data URI of that size is most of a context window by itself.
    ATTACHMENT_DATA_LIMIT = 8.megabytes
    # Inlined text attachments are cut here: enough for a CSV or a config
    # file, not enough for a log dump to crowd out the conversation.
    ATTACHMENT_TEXT_LIMIT = 20_000
    # ...and only this many bytes are ever read to produce those characters,
    # so a multi-gigabyte log named .csv costs a fixed slice of memory rather
    # than its whole size. Four bytes per character is UTF-8's worst case.
    ATTACHMENT_TEXT_BYTE_LIMIT = ATTACHMENT_TEXT_LIMIT * 4
    # What one prompt-span attribute stores. The value is a preview for reading,
    # so it is clipped; a size that has to stay exact travels as its own
    # `*.tokens` attribute instead.
    PROMPT_SPAN_ATTRIBUTE_LIMIT = 6000
    # The prompt span records the transcript, not the data URIs; keep the
    # whole serialized list within the same budget as the other attributes.
    PROMPT_SPAN_MESSAGE_LIMIT = PROMPT_SPAN_ATTRIBUTE_LIMIT
    # Prior turns sent with a pinned conversation: the most recent ones,
    # trimmed oldest-first to a character budget.
    HISTORY_TURN_LIMIT = 40
    HISTORY_CHAR_BUDGET = 60_000

    # +resume+ continues a run that paused for input (AgentResumeJob):
    #
    #   checkpoint  the checkpoint the pause stored
    #   answers     an answer per paused tool call id; false declines
    #   secrets     the pause's `:secret` answers, scrubbed from everything
    #               this execution records
    def self.call(agent_record, run, resume: nil)
      new(agent_record, run, resume: resume).call
    end

    # Returns the providers in Agent::PROVIDERS a run on +owner+'s behalf,
    # started by +actor+, has credentials for, in that order (see
    # #available_providers).
    def self.available_providers(owner, actor: nil)
      new(nil, nil, owner: owner, actor: actor).available_providers
    end

    # Tool-call keywords that name the caller. The model's arguments and the
    # run's actor share one keyword namespace by the time they reach a tool,
    # so anything a model emits under these names is dropped before the call:
    # an actor a model can name is not an authorization boundary, and the
    # documents a model reads are attacker-reachable.
    ACTOR_KEYWORDS = %i[actor current_user].freeze

    # +owner+ is whose provider credentials the run uses: the agent record's
    # owner unless given. +actor+ is who those credentials are resolved for
    # (see ProviderCredentials): the run's actor unless given. +resume+ carries
    # a paused run's checkpoint and the secret answers it was given.
    def initialize(agent_record, run, owner: nil, actor: nil, resume: nil)
      @agent_record = agent_record
      @run = run
      @owner = owner
      @credentials_actor = actor
      @resume = resume
      @secrets = Array(resume&.dig(:secrets)).map(&:to_s)
      @tool_invocations = []
      @event_sequence = resume ? recorded_event_count : 0
    end

    # Whether this execution continues a run that paused for input.
    def resuming?
      !@resume.nil?
    end

    # Returns the providers in Agent::PROVIDERS the owner's credentials, or
    # the host's config, let a run use: #provider_available? for each. A
    # provider whose credentials cannot be resolved is left out.
    # @return [Array<String>]
    def available_providers
      Agent::PROVIDERS.select do |name|
        provider_available?(name)
      rescue ProviderCredentials::Unresolved
        false
      end
    end

    # The caller this run executes on behalf of, or nil when it runs
    # unattributed. Passed to every tool as +actor:+ — a host's SchemaTools
    # scope block, Pundit policy or agent callback decides what that means.
    # @return [Object, nil]
    def actor
      @run.actor
    end

    # Emits a progress event on the run (streamed to the UI by pollers).
    # Never lets telemetry break execution.
    def emit_event(**kwargs)
      kwargs[:detail] = scrub_secrets(kwargs[:detail]) if kwargs.key?(:detail)
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
      @agent_record.ensure_executable!
      mcp_dispatcher.ensure_extra_servers_live!
      root_span = @root_span = build_root_span
      # A resumed segment sends the conversation its pause stored; the prompt
      # span of the run's first segment already shows it.
      record_prompt_span(root_span) unless resuming?
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
        paused = response.respond_to?(:awaiting_input?) && response.awaiting_input?
        tool_calls = record_tool_spans(root_span, response)
        # A paused turn's calls have no results yet; the segment that
        # finishes the run persists the whole exchange once.
        persist_tool_messages(response) unless paused
        sync_context_instructions
        root_span.set_attribute("agent.awaiting_input", true) if paused
        root_span.finish

        result = {
          output: paused ? nil : response.message&.content,
          metadata: {
            provider: provider.to_s,
            model: model,
            action: action_name,
            instructions: composed_instructions,
            requested_provider: @agent_record.provider,
            trace_id: root_span.trace_id,
            context_id: conversation_context&.id,
            tool_calls: earlier_tool_calls + tool_calls
          },
          usage: {
            input_tokens: input,
            output_tokens: output,
            total_tokens: usage&.total_tokens || input + output + thinking
          }
        }
        result.merge!(input_requests: response.input_requests, checkpoint: response.checkpoint) if paused
        result
      rescue StandardError => e
        llm_span.record_error(e)
        llm_span.finish
        root_span.record_error(e)
        root_span.finish
        emit_event(eid: llm_eid, kind: "llm", label: "#{provider}/#{model} generating", status: "error", detail: e.message)
        raise
      ensure
        record_trace(root_span)
        finish_browser_recording
      end
    end

    # The outbound prompt as a span, in the SDK's attribute shape — gives the
    # Traces UI its System/User conversation rows and lets the context-pressure
    # meter attribute instructions and tool schemas instead of lumping the
    # whole input into "messages". Messages are the text-only transcript:
    # the same list the provider gets, with data URIs replaced by
    # "[image: sales_chart.png]" placeholders.
    def record_prompt_span(root_span)
      span = root_span.add_span("agent.prompt", span_type: :prompt)
      if composed_instructions.present?
        instructions = composed_instructions.to_s
        span.set_attribute("prompt.input.instructions", instructions.byteslice(0, PROMPT_SPAN_ATTRIBUTE_LIMIT).to_s.scrub)
        span.set_attribute("prompt.input.instructions.tokens", estimated_tokens(instructions))
      end
      # MCP and toolbox schemas are attributed separately so the meter can name
      # which half fills the window, and each carries its size. The content
      # attributes are truncated previews for reading: sizing the context from
      # one understates it by whatever the clip dropped, which for a twelve-tool
      # agent is most of the schema.
      record_tool_schema_attributes(span)
      full_transcript_json = prompt_turn[:transcript].map do |message|
        { role: message[:role], content: message[:content].to_s }
      end.to_json
      transcript = prompt_turn[:transcript].map do |message|
        { role: message[:role], content: message[:content].to_s.byteslice(0, 4000).to_s.scrub }
      end
      # A replayed conversation is re-sent every turn, so the span keeps the
      # most recent messages that fit rather than the whole history again.
      serialized = transcript.to_json
      while serialized.bytesize > PROMPT_SPAN_MESSAGE_LIMIT && transcript.size > 1
        transcript.shift
        serialized = transcript.to_json
      end
      span.set_attribute("prompt.input.messages", serialized)
      span.set_attribute("messages.count", transcript.size)
      # The stored attribute is the tail of the history that fit, so its size is
      # not the transcript's. The meter apportions the provider's prompt_tokens
      # across the segments it can size, and a transcript missing from that set
      # is not merely imprecise: the segments that remain are scaled up to cover
      # it, so a long conversation reads as an enormous system prompt. Measured
      # over the full turn, before either the per-message clip or the trim.
      span.set_attribute("prompt.input.messages.tokens", estimated_tokens(full_transcript_json))
      span.finish
    rescue StandardError => e
      Rails.logger.warn("[AgentExecutionService] prompt span failed: #{e.message}")
    end

    # The list handed to prompt(messages:): the pinned conversation's prior
    # turns, then the new user turn carrying the run's attachments — images
    # and PDFs as data URIs in the provider-neutral {text:, image:} /
    # {document:} shorthand, text files inlined, anything else described.
    # Memoized, so the provider and the prompt span see one list.
    def prompt_messages
      prompt_turn[:messages]
    end

    # Persists the tool calls this service executed when the provider's
    # response carries no tool-role messages to persist them from (the
    # OpenAI Responses API). With such messages present the usual path
    # — solid_agent's, then #persist_tool_messages — already writes the
    # rows, keyed by tool_call_id, and this is a no-op.
    def persist_tool_invocations(context, response)
      return unless context.respond_to?(:add_tool_message)
      return if response.try(:awaiting_input?)
      return if completed_tool_invocations.empty?
      return if Array(response.respond_to?(:messages) ? response.messages : nil).any? do |message|
        message.respond_to?(:role) && message.role.to_s == "tool"
      end

      completed_tool_invocations.each do |invocation|
        context.add_tool_message(
          tool_call_id: nil,
          tool_name: invocation[:name],
          result: invocation[:result],
          arguments: invocation[:arguments],
          duration_ms: invocation[:duration_ms]
        )
      end
    rescue StandardError => e
      Rails.logger.error("[AgentExecutionService] Failed to persist tool invocations: #{e.message}")
    end

    # The person's own words for this turn — what the persisted user
    # message says, without the file bodies inlined for the model.
    def user_text
      @run.input_prompt.to_s.presence || (attachment_records.any? ? "(see attached files)" : "")
    end

    # What was attached, as stored on the persisted user message so the
    # conversation shows the files afterwards.
    def attachment_manifest
      @attachment_manifest ||= @run.attachment_manifest
    end

    # Per-run provider/model overrides (input_params) let callers replay the
    # same agent under a different model — the basis of evaluation comparison
    # runs. Absent overrides, the agent's own configuration applies.
    def run_params
      @run_params ||= (@run.input_params || {}).with_indifferent_access
    end

    # A resumed run keeps the provider and model it paused on: its checkpoint
    # holds that provider's native messages, even if the agent was edited
    # since.
    def requested_provider
      @requested_provider ||= (paused_metadata["provider"].presence || run_params[:provider_override].presence || @agent_record.provider).to_s
    end

    def requested_model
      @requested_model ||= paused_metadata["model"].presence || run_params[:model_override].presence || @agent_record.model
    end

    def paused_metadata
      resuming? ? @run.output_metadata.to_h : {}
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
    #
    # A call that asks a person returns an ActiveAgent::InputRequest, which
    # pauses the run: the input tools, and any tool on the agent's
    # approval_required_tools until its call is approved. The span and the
    # run's events mark such a call as awaiting rather than done.
    def execute_tool(name, **kwargs)
      forged = kwargs.slice(*ACTOR_KEYWORDS)
      if forged.any?
        Rails.logger.warn("[AgentExecutionService] dropped caller-named arguments from #{name}: #{forged.keys.join(', ')}")
        kwargs = kwargs.except(*ACTOR_KEYWORDS)
      end

      # Record the absolute URL browse_page will actually fetch, not the bare
      # path the model passed — spans/events/persisted args stay unambiguous.
      kwargs[:url] = AgentToolbox.resolve_browse_url(kwargs[:url]) if name.to_s == "browse_page" && kwargs[:url]

      tool_call_id = ActiveAgent::InputRequest.current_tool_call_id
      span = @root_span&.add_span("tool.#{name}", span_type: :tool)
      span&.set_attribute("tool.name", name.to_s)
      # tool.input.args is the key the Traces UI and TraceInteractionSerializer
      # read — the call's in: side.
      span&.set_attribute("tool.input.args", scrub_secrets(kwargs.to_json).byteslice(0, 500).to_s.scrub) if kwargs.present?
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      event_kind = name.to_s == "call_agent" ? "agent" : "tool"
      event_label = name.to_s == "call_agent" ? "call_agent → #{kwargs[:slug]}" : name.to_s
      event_id = next_event_id
      emit_event(eid: event_id, kind: event_kind, label: event_label, status: "started", detail: kwargs.to_json)

      result = begin
        approval_request(name, kwargs, tool_call_id) || dispatch_tool(name, kwargs, tool_call_id)
      rescue StandardError => e
        message = scrub_secrets(e.message)
        Rails.logger.warn("[AgentExecutionService] Tool #{name} failed: #{e.class} - #{message}")
        { error: "#{name} failed: #{message}" }
      end
      result = scrub_secrets(result)

      if result.is_a?(ActiveAgent::InputRequest)
        span&.set_attribute("tool.awaiting_input", true)
        span&.finish
        emit_event(eid: event_id, kind: event_kind, label: event_label, status: "awaiting", detail: result.prompt)
        @tool_invocations << { name: name.to_s, arguments: kwargs, tool_call_id: tool_call_id, awaiting_input: true }
        return result
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
        tool_call_id: tool_call_id,
        result: result,
        duration_ms: duration_ms,
        error: errored
      }

      result
    end

    private

    # -- Browser runs: recording and handoff ---------------------------------
    #
    # An agent with the +playwright_mcp+ tools drives the platform's browser.
    # Its browser tool calls are written to a SessionRecording tied to the run,
    # so Session Replay plays the run back; and when the page asks for
    # something only a person may give, the agent calls +request_handoff+,
    # which stores the page URL and the values entered so far on that
    # recording. Session Replay's Take Over Session then opens that page for
    # the person — the agent registers, the person pays.

    # At most this many entered values are kept, each clipped to this length.
    HANDOFF_FORM_VALUE_LIMIT = 40
    HANDOFF_FORM_VALUE_LENGTH = 200
    # A value under a key that looks like a secret is never stored: a person
    # checks what the agent filled in, not what the agent must never see.
    HANDOFF_SECRET_KEY = /card|cvc|cvv|expir|password|passcode|secret|token|otp|ssn|iban|account.?number/i

    def browser_tools_enabled?
      Array(@agent_record.tools).map(&:to_s).include?("playwright_mcp")
    end

    def request_handoff(reason: nil, url: nil, form_values: nil, instructions: nil)
      unless browser_tools_enabled?
        return { error: "request_handoff needs the browser tools (playwright_mcp) enabled on this agent" }
      end
      return { error: "request_handoff needs the url of the page the person continues on" } if url.blank?

      middleware = browser_recorder
      return { error: "request_handoff could not open the run's session recording" } unless middleware.recording

      reason = reason.to_s.strip.presence || "a step only a person can take"
      values = handoff_form_values(form_values)
      middleware.capture_for_handoff(url: url.to_s, form_values: values)
      middleware.recording_service.handoff(reason: reason, url: url.to_s, instructions: instructions.presence)
      recording = middleware.recording_service.recording
      @run.add_log("Handoff requested: #{reason} at #{url}")

      {
        handed_off: true,
        recording_id: recording.id,
        url: url.to_s,
        reason: reason,
        form_values: values,
        message: "Stopped before #{reason}. A person continues from Session Replay → Take Over Session. " \
                 "Take no further browser actions; report where you stopped and what you entered."
      }
    end

    def handoff_form_values(values)
      return nil unless values.respond_to?(:to_h)

      values.to_h.first(HANDOFF_FORM_VALUE_LIMIT).each_with_object({}) do |(key, value), kept|
        next if key.to_s.match?(HANDOFF_SECRET_KEY)
        next unless value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false

        kept[key.to_s] = value.to_s.byteslice(0, HANDOFF_FORM_VALUE_LENGTH).to_s.scrub
      end.presence
    end

    # Closes the run's recording when the run recorded anything. A run whose
    # tools never touched the browser has no recording, and gets none here.
    def finish_browser_recording
      @browser_recorder&.complete! if @browser_recorder&.recording_started?
    rescue StandardError => e
      Rails.logger.warn("[AgentExecutionService] could not complete the session recording: #{e.message}")
    end

    # Routes one tool call to its implementation. A run with an engine
    # toolset reaches that toolset and request_secret, and nothing else.
    def dispatch_tool(name, kwargs, tool_call_id)
      if engine_toolset
        return request_secret(tool_call_id, kwargs) if name.to_s == "request_secret"

        return engine_toolset.call(name.to_s, kwargs)
      end

      case name.to_s
      when "ask_user" then ask_user(tool_call_id, kwargs)
      when "request_approval" then request_approval(tool_call_id, kwargs)
      when "request_secret" then request_secret(tool_call_id, kwargs)
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
      when "request_handoff"
        request_handoff(**kwargs.slice(:reason, :url, :form_values, :instructions))
      else
        # A tool one of the agent's own MCP servers serves is called there;
        # AgentToolbox answers the rest. A browser action is also written to
        # the run's session recording, so the run plays back in Session Replay
        # and can hand off.
        # `actor:` comes from the run, never from kwargs (see
        # ACTOR_KEYWORDS): it is who the run is for, not what it is about.
        browser_recorder.intercept(tool_name: name.to_s, parameters: kwargs) do
          mcp_dispatcher.call(name, kwargs) || AgentToolbox.call(name, actor: actor, **kwargs)
        end
      end
    end

    # A confirm request for a call to a tool on the agent's approval list,
    # until a person approved that call. A declined call is never dispatched
    # again, so it does not reach this. The input tools ask on their own and
    # are never gated.
    def approval_request(name, kwargs, tool_call_id)
      return nil if AgentToolbox::INPUT_FUNCTIONS.include?(name.to_s)
      return nil unless @agent_record.approval_required_tools.include?(name.to_s)
      return nil if ActiveAgent::InputRequest.answer_for(tool_call_id) == true

      ActiveAgent::InputRequest.confirm("Allow #{name} to run?", metadata: { arguments: kwargs })
    end

    # Asks a question, or, with options, for one of them. Dispatched again
    # with the answer, it returns that answer as the call's result.
    def ask_user(tool_call_id, kwargs)
      answer = ActiveAgent::InputRequest.answer_for(tool_call_id)
      return { answer: answer } unless answer.nil?

      question = kwargs[:question].to_s
      options = Array(kwargs[:options]).map(&:to_s).reject(&:blank?)
      return ActiveAgent::InputRequest.text(question) if options.empty?

      ActiveAgent::InputRequest.choice(question, options: options)
    end

    # Asks a person to approve the action the model describes.
    def request_approval(tool_call_id, kwargs)
      return { approved: true } if ActiveAgent::InputRequest.answer_for(tool_call_id) == true

      ActiveAgent::InputRequest.confirm(kwargs[:action].to_s, metadata: { arguments: kwargs })
    end

    # Asks a person for a secret and, dispatched again with it, hands the
    # value to the agent's registered handler (SecretRequests). The model
    # reads only that it was provided.
    def request_secret(tool_call_id, kwargs)
      handler = SecretRequests.handler_for(@agent_record)
      return { error: "request_secret is not available to this agent" } unless handler

      name = kwargs[:name].to_s
      value = ActiveAgent::InputRequest.answer_for(tool_call_id)
      if value.nil?
        refusal = SecretRequests.refusal(@agent_record, run: @run, name: name)
        return { error: refusal } if refusal

        return ActiveAgent::InputRequest.secret(
          SecretRequests.prompt(@agent_record, run: @run, name: name, prompt: kwargs[:prompt].presence || "Provide #{name}")
        )
      end

      arguments = { run: @run, name: name, value: value.to_s }
      arguments[:tool_call_id] = tool_call_id if takes_keyword?(handler, :tool_call_id)
      handler.call(**arguments)
      { provided: true, name: name }
    end

    # Whether +callable+ (a block, or an object's #call) takes +keyword+.
    def takes_keyword?(callable, keyword)
      parameters = callable.is_a?(Proc) ? callable.parameters : callable.method(:call).parameters
      parameters.any? { |type, name| type == :keyrest || (%i[key keyreq].include?(type) && name == keyword) }
    end

    # The names of the tools the run's earlier segments called, for a resumed
    # run's metadata; empty for a run's first segment.
    def earlier_tool_calls
      return [] unless resuming?

      Array(@run.output_metadata.to_h["tool_calls"])
    end

    # How many progress events the run already holds, so a resumed segment's
    # event ids do not repeat its earlier segments'.
    def recorded_event_count
      Array(@run.logs).count { |entry| entry.is_a?(Hash) && entry.key?("eid") }
    end

    # Returns +value+ with every secret answer this execution was given
    # replaced by ActiveAgent::InputRequest::FILTERED.
    def scrub_secrets(value)
      @secrets.empty? ? value : ActiveAgent::InputRequest.scrub(value, @secrets)
    end

    # Returns a flattened span with the secrets scrubbed from its attribute
    # values, status message and events. Its ids, name and every key are kept
    # whole, so a secret can never break the span's links to its parent.
    def scrub_span(span)
      return span if @secrets.empty?

      span.merge(
        "attributes" => scrub_values(span["attributes"]),
        "status_message" => scrub_secrets(span["status_message"]),
        "events" => scrub_values(span["events"])
      )
    end

    # Returns +value+ with the secrets scrubbed from the values at any depth
    # of a Hash or Array, and every Hash key as it is.
    def scrub_values(value)
      case value
      when Hash then value.transform_values { |item| scrub_values(item) }
      when Array then value.map { |item| scrub_values(item) }
      else scrub_secrets(value)
      end
    end

    # Options added to the provider's for this run, such as a
    # max_tool_turns cap above the provider's default.
    def generation_options
      {}
    end

    # Maximum agent-to-agent delegation depth for the call_agent tool. A
    # thread-local counter guards it because the sub-agent runs synchronously
    # on the same thread via Agent#test_execute.
    MAX_CALL_DEPTH = 2

    # Executes another agent of the same account synchronously and returns
    # its reply, so agents can delegate to each other as a tool call. The
    # sub-run is a real AgentRun with its own trace.
    # One dispatcher per run, so every tool call shares the MCP sessions the
    # first call opens. A run given a checkout sandbox (an evaluation or a
    # runner run against it) reaches that runtime too, and the sandbox's
    # browser when it was running as the run was created.
    def mcp_dispatcher
      @mcp_dispatcher ||= MCPToolDispatcher.new(
        @agent_record, extra_server_keys: [ @run.try(:sandbox_server_key), @run.try(:browser_server_key) ].compact
      )
    end

    # How many rows of each credential the recording secrets are read from.
    RECORDING_SECRET_LOOKUP_LIMIT = 50

    def browser_recorder
      @browser_recorder ||= MCPRecordingMiddleware.new(agent_run: @run, secrets: -> { recording_secrets })
    end

    # The credentials the run's owner holds, scrubbed from the browser
    # actions the run records: provider keys, the GitHub token, and the
    # runtime and browser tokens of the sandbox the run reaches.
    def recording_secrets
      sandbox_id = @run.try(:sandbox_id)
      sandbox = sandbox_id && SandboxSession.for_owner(owner).find_by(session_id: sandbox_id)
      [
        *ProviderKey.for_owner(owner).limit(RECORDING_SECRET_LOOKUP_LIMIT).pluck(:credential, :api_key).flatten,
        *GithubConnection.for_owner(owner).limit(RECORDING_SECRET_LOOKUP_LIMIT).pluck(:access_token),
        sandbox&.runtime_mcp_token,
        sandbox&.browser_token,
        *owner_provider_options(requested_provider).values_at(:access_token, :api_key)
      ].compact
    end

    # Splits the offered schemas the way `tool_schemas` assembles them, so the
    # span reports what the model was actually sent: nothing for a mock run, and
    # one MCP round trip rather than a second one for telemetry.
    def record_tool_schema_attributes(span)
      mcp_definitions, toolbox_definitions = tool_schema_halves
      {
        "prompt.input.tools" => toolbox_definitions,
        "prompt.input.mcp_tools" => mcp_definitions
      }.each do |key, definitions|
        next if definitions.blank?

        json = definitions.to_json
        span.set_attribute(key, json.byteslice(0, PROMPT_SPAN_ATTRIBUTE_LIMIT).to_s.scrub)
        span.set_attribute("#{key}.tokens", estimated_tokens(json))
      end
    end

    # ~4 chars/token, the same approximation the context meter applies to content
    # it sizes itself. Taken before truncation, so the meter reads the whole
    # schema rather than the preview the attribute stores.
    def estimated_tokens(text)
      (text.length / 4.0).round
    end

    def call_agent(slug:, message:)
      depth = Thread.current[:agent_call_depth].to_i
      return { error: "call_agent depth limit (#{MAX_CALL_DEPTH}) reached" } if depth >= MAX_CALL_DEPTH

      target = workspace_agents.where.not(id: @agent_record.id).find_by(slug: slug.to_s)
      return { error: "No agent with slug '#{slug}' in this workspace" } unless target

      Thread.current[:agent_call_depth] = depth + 1
      begin
        sub_run = target.test_execute(message.to_s)
        return delegated_input_required(target, sub_run) if sub_run.awaiting_input?

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

    # A called agent that paused to ask a person cannot be resumed from here:
    # nothing holds its checkpoint once this call returns. Its requests are
    # cancelled, and its questions go back to the calling model, in the
    # shape a framework delegation that paused returns.
    def delegated_input_required(target, sub_run)
      questions = sub_run.input_requests.pending.order(:id).pluck(:prompt)
      sub_run.cancel!("Paused for input, which an agent called with call_agent cannot do")

      {
        error: "input_required",
        agent: target.slug,
        run_id: sub_run.id,
        questions: questions,
        message: "#{target.slug} stopped to ask the user for input, which an agent called with call_agent cannot do. " \
                 "Answer with the information you already have, or ask the user yourself."
      }
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
      # Pinned, or the default stream resolved here rather than left to
      # solid_agent's unordered find_or_create_by!, which cannot tell the
      # agent's original conversation from a later one on the same triple.
      pinned = conversation_context
      instructions = composed_instructions
      action = action_name
      run_trace_id = trace_id
      tool_definitions = tool_schemas
      extra_options = generation_options
      service = self

      # A dashboard-authored agent has no Ruby class — it is rows: a tool
      # selection, instructions typed in the builder. That is the common case
      # and the runtime below builds a class for it.
      #
      # An agent mirrored from host code is the other case: the class exists,
      # already declares its own tools (SchemaTools rosters, delegations) and
      # renders its own instructions, and none of that is reachable through
      # `tools` + `instructions` columns. Running the real class keeps the
      # dashboard evaluating what production runs, instead of a rebuilt
      # lookalike. Both runtimes stay; which one applies is decided by whether
      # the class resolves.
      if (host_class = resolved_host_class)
        return run_host_class(host_class, actor: actor, action: action, run_trace_id: run_trace_id)
      end
      resume = @resume

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
          generate_with :mock, **extra_options
        else
          generate_with effective_provider, model: provider_model, **model_options, **extra_options
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
        # each action gets its own interaction stream. A run pinned to a
        # conversation continues that context instead.
        define_method action do
          # Thread the run's telemetry trace_id through prompt_options so
          # SolidAgent's provenance (and AgentContext#record_generation_with_
          # provenance!) can correlate the persisted generation with its trace.
          prompt_options[:trace_id] = run_trace_id
          if pinned
            load_context(context_id: pinned.id)
          else
            load_context(contextable: agent_record)
          end

          # A resume replaces the conversation with its checkpoint's.
          options = { messages: resume ? [] : service.prompt_messages }
          options[:instructions] = instructions if instructions.present?
          options[:tools] = tool_definitions if tool_definitions.present?
          prompt(**options)
        end

        # solid_agent's after_prompt callback persists the last prompt
        # message's content: string — so a turn that carries files (a
        # {text:, image:} hash) would never be written, and the history
        # replayed from the pinned context is not this run's to persist.
        # Instead: exactly one user message per run, through the agent-level
        # add_user_message that stamps provenance (its trace_id is how the
        # run detail API finds the run's slice of the conversation), with
        # the attachment manifest alongside.
        define_method(:persist_prompt_to_context) do
          return if resuming?

          text = service.user_text
          return unless context && text.present?

          add_user_message(text, attachments: service.attachment_manifest)
        end
        private :persist_prompt_to_context

        # A paused generation has no reply yet, and its tool-call turn holds
        # calls without results. The segment that finishes the run records
        # the reply and the whole tool exchange.
        define_method(:persist_generation_to_context) do
          return if generation_response.try(:awaiting_input?)

          super()
        end
        private :persist_generation_to_context

        # solid_agent persists the tool exchange from the response's
        # tool-role messages. The Responses API carries function calls as
        # items rather than messages, so that list is empty and the
        # exchange — a render_ui call is the reply — would vanish from the
        # conversation. The service saw every call go by; fall back to its
        # own records, here so the rows land before the assistant turn.
        define_method(:persist_tool_messages_to_context) do
          super()
          service.persist_tool_invocations(context, generation_response)
        end
        private :persist_tool_messages_to_context
      end

      # `as` carries the caller onto the agent instance, so an agent's own
      # before_action callbacks (ActiveAgent::Authorization) authorize
      # against the same person the tools are scoped to.
      perform(agent_class.as(actor).public_send(action))
    end

    # Generates, or continues the paused generation this execution resumes.
    def perform(generation)
      return generation.generate_now unless resuming?

      generation.resume_now(checkpoint: @resume[:checkpoint], answers: @resume[:answers])
    end

    # Function-calling schemas for the agent's enabled tools that have
    # server-side implementations (none for mock runs — the mock provider
    # doesn't do tool calling).
    def tool_schemas
      mcp_definitions, toolbox_definitions = tool_schema_halves
      mcp_definitions + toolbox_definitions
    end

    # The agent's own MCP servers describe their tools; the toolbox describes the
    # rest. Without the first half a tool the agent declares is never offered to
    # the model, which then answers from memory instead of calling it. Memoized
    # because listing a server's tools is a request to that server.
    #
    # A run that reaches its sandbox's browser gets the browser's tools from
    # the MCP half only: the toolbox's browser tools have the same names, and
    # a provider refuses a tool list that names one twice.
    def tool_schema_halves
      @tool_schema_halves ||=
        if provider == :mock
          [ [], [] ]
        elsif engine_toolset
          [ [], engine_toolset.definitions ]
        else
          [
            mcp_dispatcher.tool_definitions,
            AgentToolbox.definitions_for(@agent_record.tools, browser_attached: mcp_dispatcher.browser_attached?) + secret_request_definitions
          ]
        end
    end

    # The tools of a run the engine started for an agent it defines (see
    # ProjectSetup.toolset_for). They replace whatever tools and MCP servers
    # the agent record names. Nil for any other run.
    def engine_toolset
      return @engine_toolset if defined?(@engine_toolset)

      @engine_toolset = ProjectSetup.toolset_for(@agent_record, @run)
    end

    # request_secret, for an agent the engine registered a handler for.
    def secret_request_definitions
      SecretRequests.handler_for(@agent_record) ? [ AgentToolbox::REQUEST_SECRET_DEFINITION ] : []
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
        # back to the service's own invocation record.
        invocation = tool_invocation_for(tool_call_id, index)
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

    # The calls this execution ran to a result: not the ones that asked a
    # person and left the run paused.
    def completed_tool_invocations
      @tool_invocations.reject { |invocation| invocation[:awaiting_input] }
    end

    # The invocation record for a response's tool message: by tool call id
    # when both carry one, else by position among the tool messages. A
    # resumed segment's response also holds the tool messages of earlier
    # segments, which have no record here, so it matches by id only.
    def tool_invocation_for(tool_call_id, index)
      invocations = completed_tool_invocations
      if tool_call_id.present?
        match = invocations.find { |invocation| invocation[:tool_call_id].to_s == tool_call_id.to_s }
        return match if match
      end

      invocations[index] unless resuming?
    end

    # Tool names for run metadata. Spans are recorded live in execute_tool;
    # the response-message scan only covers calls the provider executed
    # without routing through the service (none today, but cheap insurance).
    def record_tool_spans(root_span, response)
      return completed_tool_invocations.map { |invocation| invocation[:name] } if @tool_invocations.any?

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

    # The host class this agent mirrors, when it names one that resolves to a
    # runnable ActiveAgent::Base subclass. Anything else — no class name, a
    # class that no longer exists, a name that resolves to something else — is
    # nil, and the dynamic runtime handles the record as before.
    #
    # @return [Class, nil]
    def resolved_host_class
      return nil unless ActionAgent.run_host_agent_classes

      name = @agent_record.agent_class_name.presence
      return nil if name.blank?

      klass = name.safe_constantize
      klass if klass.is_a?(Class) && klass < ActiveAgent::Base
    end

    # Runs the host's own class. Its tools, delegations and instructions come
    # from the code, so the engine supplies only what is the run's business:
    # the caller, and the trace to correlate against.
    def run_host_class(klass, actor:, action:, run_trace_id:)
      generation = klass.as(actor).public_send(action, **host_action_arguments(klass, action))
      generation.prompt_options[:trace_id] = run_trace_id if generation.respond_to?(:prompt_options)
      perform(generation)
    end

    # A code agent's action takes named arguments (`ask(question:)`), so the
    # run's message is passed under the action's own keyword rather than as a
    # bare message the signature would reject.
    def host_action_arguments(klass, action)
      contract = klass.try(:delegation_contracts)&.dig(action.to_sym)
      keyword = contract&.try(:parameters)&.keys&.first
      keyword ? { keyword.to_sym => user_text } : {}
    end

    # Unresolved credentials propagate, so the run fails with that error
    # rather than with ProviderNotConfiguredError.
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
    rescue ProviderCredentials::Unresolved
      raise
    rescue StandardError
      false
    end

    # Credential overrides for +name+, as ProviderCredentials resolves them
    # for this owner and actor.
    def owner_provider_options(name)
      @owner_provider_options ||= {}
      @owner_provider_options[name.to_s] ||=
        ProviderCredentials.resolve(owner: owner, actor: credentials_actor, provider: name).options
    end

    def credentials_actor
      @credentials_actor || @run&.actor
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

    # The solid_agent conversation context this execution persisted into:
    # the pinned one when the run continues a conversation, else the
    # agent + action's default stream.
    def conversation_context
      pinned_context || default_stream_context
    end

    # The agent + action's default stream: the oldest context on the triple
    # solid_agent keys by, so a second conversation the dashboard started for
    # the same action cannot become the row an unpinned run appends to.
    def default_stream_context
      AgentContext.where(contextable: @agent_record, agent_name: agent_class_name, action_name: action_name)
        .order(:id).first
    end

    # The conversation the run was pinned to (input_params context_id). A
    # context belonging to another agent — or recorded under another action,
    # whose instructions and stream are not this run's — is ignored rather
    # than continued: the run falls back to the default stream as if nothing
    # had been pinned, and reports the conversation it actually wrote to.
    def pinned_context
      return @pinned_context if defined?(@pinned_context)

      id = run_params[:context_id]
      @pinned_context =
        if id.present?
          # Matched on the action too, not just ownership: a run for another
          # action would append to this conversation and rewrite the recorded
          # instructions with its own. The agent_name is deliberately not part
          # of it — renaming an agent changes that string, and the
          # conversations it already has must stay pinnable.
          AgentContext.find_by(id: id, contextable: @agent_record, action_name: action_name)
        end
    end

    # The pinned conversation's prior turns as plain {role:, content:}
    # messages — the conversation as the person saw it: tool rows and empty
    # assistant rows (a turn that only carried a tool call) are skipped.
    # The most recent turns, dropped oldest-first once the budget is spent.
    def history_messages
      context = pinned_context
      return [] unless context

      turns = context.messages.chronological
        .where(role: %w[user assistant])
        .where.not(content: [ nil, "" ])
        .last(HISTORY_TURN_LIMIT)

      budget = HISTORY_CHAR_BUDGET
      kept = turns.reverse_each.with_object([]) do |message, collected|
        content = message.content.to_s
        break collected if content.length > budget

        budget -= content.length
        collected.unshift(role: message.role, content: content)
      end

      # Neither cut lands on a turn boundary, so the oldest survivor can be an
      # assistant reply whose question was dropped. Anthropic rejects a
      # conversation that opens on one, and every provider reads it as an
      # answer to nothing.
      kept.shift while kept.first && kept.first[:role] != "user"
      kept
    end

    # Builds the message list and, in the same pass, its text-only
    # transcript for the prompt span (data URIs are too big to trace).
    #
    # The first image or document rides on the user's text as a
    # {text:, image:} / {text:, document:} message; each further one is a
    # message of its own, since the shorthand carries one part per key.
    def prompt_turn
      @prompt_turn ||= begin
        # dup: the inlined file bodies must not land on the run's own
        # input_prompt through in-place mutation.
        text = user_text.dup
        media = []

        attachment_records.each do |attachment|
          blob = attachment.blob
          filename = blob.filename.to_s
          descriptor = "#{filename} (#{blob.content_type}, #{human_size(blob.byte_size)})"

          # A file the storage service can no longer produce costs the file,
          # not the run: every branch below degrades to the same descriptor
          # the unsupported kinds get.
          begin
            case AgentRun.attachment_kind(blob.content_type, filename)
            when "text"
              body = text_prefix(blob)
              suffix = body.bytesize < blob.byte_size ? "\n… (truncated)" : ""
              text << "\n\n[Attached file: #{descriptor}]\n```\n#{body}#{suffix}\n```"
            when "image", "document"
              if blob.byte_size > ATTACHMENT_DATA_LIMIT
                text << "\n\n[Attached file: #{descriptor} — not sent to the model]"
              else
                key = blob.content_type.to_s.start_with?("image/") ? :image : :document
                media << { key => data_uri(blob), label: "[#{key}: #{filename}]" }
              end
            else
              text << "\n\n[Attached file: #{descriptor} — not sent to the model]"
            end
          rescue StandardError => e
            Rails.logger.warn("[AgentExecutionService] attachment #{filename} unreadable: #{e.message}")
            text << "\n\n[Attached file: #{descriptor} — not sent to the model]"
          end
        end

        first, *rest = media
        history = history_messages
        # No prompt and no files sends no turn at all, which leaves the
        # gem's template fallback in charge exactly as before.
        turn =
          if first
            { role: "user", text: text }.merge(first.except(:label))
          elsif text.present?
            { role: "user", content: text }
          end
        {
          messages: history + [ turn ].compact + rest.map { |item| { role: "user" }.merge(item.except(:label)) },
          transcript: history +
            [ turn && { role: "user", content: [ text, first&.dig(:label) ].compact.join("\n") } ].compact +
            rest.map { |item| { role: "user", content: item[:label] } }
        }
      end
    end

    def attachment_records
      @attachment_records ||= AgentRun.attachments_available? ? @run.attachments_attachments.includes(:blob).order(:id).to_a : []
    end

    def data_uri(blob)
      "data:#{blob.content_type};base64,#{Base64.strict_encode64(blob.download)}"
    end

    # The head of a text attachment, reading a bounded number of bytes: only
    # ATTACHMENT_TEXT_LIMIT characters are ever sent, so a huge file must not
    # be materialised whole to produce them. The byte prefix can split a
    # multibyte character, which scrub removes.
    def text_prefix(blob)
      bytes =
        if blob.byte_size <= ATTACHMENT_TEXT_BYTE_LIMIT
          blob.download
        elsif blob.service.respond_to?(:download_chunk)
          blob.service.download_chunk(blob.key, 0...ATTACHMENT_TEXT_BYTE_LIMIT)
        else
          buffer = +""
          blob.download do |chunk|
            buffer << chunk
            break if buffer.bytesize >= ATTACHMENT_TEXT_BYTE_LIMIT
          end
          buffer
        end

      bytes.to_s.dup.force_encoding(Encoding::UTF_8).scrub[0, ATTACHMENT_TEXT_LIMIT]
    end

    def human_size(bytes)
      ActiveSupport::NumberHelper.number_to_human_size(bytes, precision: 2)
    end

    # The agent's owner under the configured mode; nil when the install
    # has no owner model at all.
    def owner
      @owner ||= @agent_record&.owner
    end

    def record_trace(root_span)
      payload = {
        trace_id: root_span.trace_id,
        service_name: SERVICE_NAME,
        environment: Rails.env,
        timestamp: Time.current.iso8601(6),
        resource_attributes: { "platform.agent_id" => @agent_record.id, "platform.run_id" => @run.id },
        spans: flatten_spans(root_span).map { |span| scrub_span(span) }
      }.as_json

      sdk_info = {
        name: "activeagent",
        version: ActiveAgent::VERSION,
        language: "ruby",
        runtime_version: RUBY_VERSION
      }.as_json

      trace_model = ActionAgent.trace_model
      tenant = ActionAgent.tenant_for(owner)
      existing = trace_model.for_account(tenant).find_by(trace_id: root_span.trace_id)
      # A resumed segment shares its run's trace id, and its spans join the
      # trace the run's earlier segments recorded.
      if existing
        existing.append_segment!(payload["spans"]) if resuming? && existing.respond_to?(:append_segment!)
        return
      end

      trace_model.create_from_payload(payload, sdk_info, account: tenant, agent: @agent_record)
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
