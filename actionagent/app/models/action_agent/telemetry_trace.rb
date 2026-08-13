# frozen_string_literal: true

module ActionAgent
  # Stores telemetry traces from ActiveAgent clients.
  #
  # Each trace represents a complete generation lifecycle, including prompt
  # preparation, LLM calls, tool invocations, and error handling.
  #
  # This model supports two modes:
  # - Local mode: No account association (single-tenant, self-hosted)
  # - Multi-tenant mode: With account association (for activeagents.ai platform)
  #
  # @example Creating a trace from ingested data (local mode)
  #   ActionAgent::TelemetryTrace.create_from_payload(trace_payload, sdk_info)
  #
  # @example Creating a trace with account (multi-tenant mode)
  #   ActionAgent::TelemetryTrace.create_from_payload(trace_payload, sdk_info, account: account)
  #
  class TelemetryTrace < ::ActiveRecord::Base
    include ActionAgent::AdapterAware

    self.table_name = "active_agent_telemetry_traces"

    # Optional account association for multi-tenant mode
    # The host app can add: belongs_to :account if needed
    if ActionAgent.multi_tenant?
      belongs_to :account, class_name: ActionAgent.account_class
    end

    # Status values for traces
    STATUS_OK = "OK"
    STATUS_ERROR = "ERROR"
    STATUS_UNSET = "UNSET"

    validates :trace_id, presence: true

    # Scopes
    scope :recent, -> { order(timestamp: :desc) }
    scope :with_errors, -> { where(status: STATUS_ERROR) }
    scope :for_service, ->(name) { where(service_name: name) }
    scope :for_environment, ->(env) { where(environment: env) }
    scope :for_agent, ->(agent_class) { where(agent_class: agent_class) }
    scope :for_date_range, ->(start_date, end_date) { where(timestamp: start_date..end_date) }
    # The dashboard agent this trace was attributed to on ingest, if any.
    belongs_to :agent, class_name: "ActionAgent::Agent", optional: true

    scope :for_account, ->(account) { where(account: account) if ActionAgent.multi_tenant? }

    # Creates a TelemetryTrace from an ingested trace payload.
    #
    # Extracts relevant data from the trace payload and stores it in a
    # normalized format for querying and analysis.
    #
    # @param trace [Hash] The trace payload from ActiveAgent::Telemetry
    # @param sdk_info [Hash] SDK metadata
    # @param account [Object, nil] Optional account for multi-tenant mode
    # @return [TelemetryTrace] The created trace
    # Plucks [llm_model, *columns] per trace, where llm_model comes from the
    # first llm span. PostgreSQL digs into the spans jsonb in SQL so span
    # payloads never reach Ruby; other adapters read the column back and dig
    # in Ruby, which costs more but keeps the dashboard adapter-agnostic.
    def self.pluck_with_llm_model(scope, *columns)
      if postgres?
        scope.pluck(
          Arel.sql(
            # spans is cast rather than assumed to be jsonb: the column is
            # json on every install created before the migration template
            # started picking jsonb per adapter, and jsonb_array_elements
            # rejects a json argument outright.
            "(SELECT s.value -> 'attributes' ->> 'llm.model' " \
            "FROM jsonb_array_elements(spans::jsonb) AS s " \
            "WHERE s.value ->> 'type' = 'llm' LIMIT 1)"
          ),
          *columns
        )
      else
        scope.pluck(:spans, *columns).map do |spans, *rest|
          llm = Array(spans).find { |span| span.is_a?(Hash) && span["type"].to_s == "llm" }
          [ llm&.dig("attributes", "llm.model"), *rest ]
        end
      end
    end

    def self.create_from_payload(trace, sdk_info = {}, account: nil)
      spans = trace["spans"] || []
      root_span = spans.find { |s| s["parent_span_id"].nil? } || spans.first || {}

      total_duration = root_span["duration_ms"]

      # Instrumentation mirrors LLM token usage onto the root span for
      # display, so summing every span double-counts. When child spans
      # carry token data, they are the source of truth; the root span only
      # counts for single-span traces.
      counted_spans = spans.reject { |s| s["parent_span_id"].nil? }
      counted_spans = spans if counted_spans.none? { |s| span_token_sum(s).positive? }

      total_input = 0
      total_output = 0
      total_thinking = 0

      counted_spans.each do |span|
        tokens = span["tokens"] || {}
        total_input += (tokens["input"] || 0)
        total_output += (tokens["output"] || 0)
        total_thinking += (tokens["thinking"] || 0)
      end

      # Extract agent info from root span attributes
      attributes = root_span["attributes"] || {}
      agent_class = attributes["agent.class"]
      agent_action = attributes["agent.action"]

      # Find any error message
      error_span = spans.find { |s| s["status"] == STATUS_ERROR }
      error_message = error_span&.dig("attributes", "error.message")

      attrs = {
        trace_id: trace["trace_id"],
        service_name: trace["service_name"],
        environment: trace["environment"],
        timestamp: Time.parse(trace["timestamp"]),
        spans: spans,
        resource_attributes: trace["resource_attributes"],
        sdk_info: sdk_info,
        total_duration_ms: total_duration,
        total_input_tokens: total_input,
        total_output_tokens: total_output,
        total_thinking_tokens: total_thinking,
        status: root_span["status"] || STATUS_UNSET,
        agent_class: agent_class,
        agent_action: agent_action,
        error_message: error_message
      }

      # Add account if in multi-tenant mode
      attrs[:account] = account if ActionAgent.multi_tenant? && account

      create!(attrs)
    end

    # Sums a span's token counts (used to decide which spans carry the
    # authoritative token data during ingestion).
    #
    # @api private
    def self.span_token_sum(span)
      tokens = span["tokens"] || {}
      tokens.fetch("input", 0).to_i + tokens.fetch("output", 0).to_i + tokens.fetch("thinking", 0).to_i
    end

    # Returns the root span of this trace.
    #
    # @return [Hash, nil] The root span or nil
    def root_span
      spans&.find { |s| s["parent_span_id"].nil? }
    end

    # Returns all LLM spans in this trace.
    #
    # @return [Array<Hash>] LLM spans
    def llm_spans
      spans&.select { |s| s["type"] == "llm" } || []
    end

    # Returns all tool call spans in this trace.
    #
    # @return [Array<Hash>] Tool spans
    def tool_spans
      spans&.select { |s| s["type"] == "tool" } || []
    end

    # Returns each tool call in this trace, normalized for display.
    #
    # Tool spans are tagged with their origin at instrumentation time
    # (ActiveAgent::Telemetry::ToolOrigin), but traces ingested before that
    # shipped — or sent by another SDK — only carry +tool.name+. Those are
    # classified on read from the same naming convention, so a dashboard
    # sees consistent attribution across old and new traces.
    #
    # @return [Array<Hash>] one entry per tool span with :name, :base_name,
    #   :origin, :mcp_server, :duration_ms, :status, :error, :arguments and
    #   :result
    def tool_usage
      tool_spans.map do |span|
        attributes = span["attributes"] || {}
        name = attributes["tool.name"] || span["name"].to_s.delete_prefix("tool.")
        classification = classify_tool(name, attributes)

        {
          name: name,
          base_name: attributes["tool.base_name"] || classification[:tool],
          origin: attributes["tool.origin"] || classification[:origin],
          mcp_server: attributes["tool.mcp_server"] || classification[:server],
          duration_ms: span["duration_ms"],
          status: span["status"],
          error: attributes["error.message"],
          arguments: attributes["tool.input.args"],
          result: attributes["tool.output.result"]
        }
      end
    end

    # Returns the tools this trace's generation request OFFERED the
    # provider, whether or not the model went on to call any of them.
    #
    # Instrumentation records the roster on the prompt span as
    # +prompt.input.tools+ (name, description, parameter keys), which is
    # the agent's declared tool surface for that generation. Reading it
    # here is what lets a dashboard show a tool that exists but has never
    # been invoked — a state that tool spans alone can't express.
    #
    # @return [Array<Hash>] entries with :name, :description, :parameters,
    #   :origin and :mcp_server
    def declared_tools
      roster = spans.to_a.filter_map { |span| span.dig("attributes", "prompt.input.tools").presence }.first
      return [] if roster.blank?

      parsed = roster.is_a?(String) ? (JSON.parse(roster) rescue []) : roster

      Array(parsed).filter_map do |tool|
        next unless tool.is_a?(Hash)

        name = (tool["name"] || tool[:name]).to_s
        next if name.empty?

        classification = ActiveAgent::Telemetry::ToolOrigin.classify(name)
        {
          name: name,
          description: tool["description"] || tool[:description],
          parameters: Array(tool["parameters"] || tool[:parameters]),
          origin: classification[:origin],
          mcp_server: classification[:server]
        }
      end
    end

    # Returns the distinct MCP servers this trace touched — both the ones
    # it called and the ones it was merely offered.
    #
    # @return [Array<String>] server names, in first-seen order
    def mcp_servers
      (tool_usage.filter_map { |tool| tool[:mcp_server] } +
        declared_tools.filter_map { |tool| tool[:mcp_server] }).uniq
    end

    # Returns total token count.
    #
    # @return [Integer] Total tokens used
    def total_tokens
      (total_input_tokens || 0) + (total_output_tokens || 0) + (total_thinking_tokens || 0)
    end

    # Returns whether this trace had an error.
    #
    # @return [Boolean]
    def error?
      status == STATUS_ERROR
    end

    # Returns display name for the trace.
    #
    # @return [String] Display name (e.g., "WeatherAgent.forecast")
    def display_name
      if agent_class && agent_action
        "#{agent_class}.#{agent_action}"
      elsif agent_class
        agent_class
      else
        trace_id&.first(8)
      end
    end

    # Returns formatted duration.
    #
    # @return [String] Duration in ms or s
    def formatted_duration
      return "—" unless total_duration_ms

      if total_duration_ms >= 1000
        "#{(total_duration_ms / 1000.0).round(2)}s"
      else
        "#{total_duration_ms.round(0)}ms"
      end
    end

    # Returns formatted token count.
    #
    # @return [String] Token count with K suffix for large numbers
    def formatted_tokens
      count = total_tokens
      return "0" if count.zero?

      if count >= 1000
        "#{(count / 1000.0).round(1)}K"
      else
        count.to_s
      end
    end

    # Returns the provider used (from LLM spans).
    #
    # @return [String, nil] Provider name
    def provider
      llm_span = llm_spans.first
      return nil unless llm_span

      llm_span.dig("attributes", "llm.provider")
    end

    # Returns the model used (from LLM spans).
    #
    # @return [String, nil] Model name
    def model
      llm_span = llm_spans.first
      return nil unless llm_span

      llm_span.dig("attributes", "llm.model")
    end

    private

    # Recovers a tool's origin for traces that predate origin tagging.
    # Prefers an explicit server attribute when the SDK sent one, then
    # falls back to the shared name-convention classifier.
    def classify_tool(name, attributes)
      explicit = attributes["mcp.server"] || attributes["tool.server"]
      return { origin: "mcp", server: explicit, tool: name } if explicit.present?

      ActiveAgent::Telemetry::ToolOrigin.classify(name)
    end
  end
end
