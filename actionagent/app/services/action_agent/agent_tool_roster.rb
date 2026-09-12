# frozen_string_literal: true

module ActionAgent
  # One agent's tool roster, as the agent editor's Tools tab reads it: every
  # tool the agent can be offered and every MCP service it can be given, each
  # carrying what the window actually recorded for it.
  #
  # Three groups, one row vocabulary — the same one the Tools and MCP
  # Services pages use, so a roster reads the way the observability views do:
  #
  # * **Agent-defined** — tools discovered from the rosters this agent's own
  #   generations offered (ToolDiscovery's +agent+ origin). Schema-derived:
  #   the agent class declares them, so they are reported here rather than
  #   selected. Read-only for the same reason MCP rows are — a checkbox that
  #   cannot add or remove the tool is a control that changes nothing.
  # * **Dashboard** — Agent::AVAILABLE_TOOLS, the capabilities the builder
  #   offers every agent. These are the roster: +agent.tools+ is what
  #   AgentToolbox turns into function schemas at generation time.
  # * **MCP** — never stored on the roster. Computed from the services the
  #   agent enables, which is where they are edited.
  #
  # Enablement reads the agent's own configuration: +tools+ for the dashboard
  # capabilities, +mcp_servers+ for services and their per-server allow-lists
  # (an entry with no +tools+ key offers everything the server serves).
  class AgentToolRoster
    AGENT_DEFINED = "agent_defined"
    DASHBOARD = "dashboard"
    MCP = "mcp"

    # Ordering for the services list: what this agent uses, then what the
    # workspace already talks to, then the rest of the catalog.
    STATUS_RANK = { "active" => 0, "configured" => 1, "available" => 2, "idle" => 3 }.freeze

    attr_reader :agent, :discovery

    # @param agent [ActionAgent::Agent] the agent being edited
    # @param traces [ActiveRecord::Relation] the traces the caller may read
    # @param hours [Integer] the window the usage columns are scoped to
    def initialize(agent:, traces:, hours: ToolDiscovery::DEFAULT_WINDOW_HOURS)
      @agent = agent
      @discovery = ToolDiscovery.new(
        traces: traces.for_agent(agent.telemetry_agent_class),
        agents: Agent.where(id: agent.id),
        hours: hours
      )
    end

    def as_json(*)
      {
        window_hours: discovery.window_hours,
        # Whether any record source had rows in this window. False means the
        # usage columns have nothing behind them, and the view renders them
        # as "—" rather than as a row of honest-looking zeroes.
        usage_available: inventory[:sources].values.any?,
        services: services,
        tools: tools
      }
    end

    private

    def inventory
      @inventory ||= discovery.inventory
    end

    def detected
      inventory[:tools]
    end

    def saved_tools
      @saved_tools ||= Array(agent.tools).map(&:to_s)
    end

    # --- services ------------------------------------------------------

    def services
      rows = service_keys.map { |key| service_row(key) }
      rows.sort_by do |row|
        [ row[:enabled] ? 0 : 1, STATUS_RANK.fetch(row[:status], 9), -row[:calls], row[:name].to_s.downcase ]
      end
    end

    # The catalog, plus anything this agent's traffic or configuration names
    # that the catalog doesn't describe.
    def service_keys
      (MCPCatalog.keys + detected_by_server.keys + configured_servers.keys).uniq
    end

    def detected_by_server
      @detected_by_server ||= detected.reject { |tool| tool[:mcp_server].blank? }.group_by { |tool| tool[:mcp_server] }
    end

    def service_row(key)
      catalog = MCPCatalog.find(key)
      used = detected_by_server[key] || []
      calls = used.sum { |tool| tool[:calls] }
      enabled = configured_servers.key?(key)

      {
        key: key,
        name: catalog ? catalog[:name] : key,
        description: catalog&.dig(:description),
        docs_url: catalog&.dig(:docs_url),
        first_party: catalog ? catalog[:first_party] : false,
        known: !catalog.nil?,
        transport: transport_label(catalog),
        status: service_status(calls, enabled, catalog),
        enabled: enabled,
        calls: calls,
        errors: used.sum { |tool| tool[:errors] },
        last_seen: used.filter_map { |tool| tool[:last_seen] }.max,
        tools: service_tools(key, catalog, used)
      }
    end

    # How to reach the server, in the one line the expanded panel shows:
    # "Streamable HTTP · <url>" for the ones the dashboard can call,
    # "sandbox · <command>" for the ones it can start, "stdio · <command>"
    # for the rest.
    def transport_label(catalog)
      return nil if catalog.nil?

      transport = catalog[:transport].to_s
      return [ "Streamable HTTP", catalog[:url] ].compact.join(" · ") if transport == "http"

      prefix = catalog[:sandbox] ? "sandbox" : transport.presence
      [ prefix, catalog[:command] ].compact.join(" · ").presence
    end

    def service_status(calls, enabled, catalog)
      return "active" if calls.positive?
      return "configured" if enabled
      return "available" if catalog

      "idle"
    end

    # What the service offers: the catalog's tool hints unioned with the
    # tools this agent was actually seen calling on it, so a server whose
    # roster has drifted from the catalog still lists what it really serves.
    def service_tools(key, catalog, used)
      by_name = used.index_by { |tool| tool[:base_name] }
      allowed = allowed_tools(key)
      names = (Array(catalog&.dig(:tools)) + by_name.keys).uniq

      names.map do |name|
        usage_row(by_name[name]).merge(
          name: name,
          description: by_name[name]&.dig(:description),
          enabled: allowed.nil? || allowed.include?(name)
        )
      end
    end

    # --- tools ---------------------------------------------------------

    def tools
      agent_defined_rows + dashboard_rows
    end

    # Schema-derived tools: whatever this agent's generations offered that
    # is neither an MCP tool nor one of the dashboard's own.
    def agent_defined_rows
      detected
        .select { |tool| tool[:origin] == ToolDiscovery::ORIGIN_AGENT }
        .reject { |tool| dashboard_function_names.include?(tool[:name]) }
        .map do |tool|
          usage_row(tool).merge(
            key: tool[:name],
            name: tool[:name],
            source: AGENT_DEFINED,
            description: tool[:description],
            # The agent class declares these; the dashboard reports them.
            enabled: true,
            editable: false
          )
        end
    end

    def dashboard_rows
      Agent::AVAILABLE_TOOLS.map do |capability|
        usage_row(capability_usage(capability)).merge(
          key: capability,
          name: capability,
          source: DASHBOARD,
          description: Agent::TOOL_DESCRIPTIONS[capability],
          enabled: saved_tools.include?(capability),
          editable: true
        )
      end
    end

    # A capability is one checkbox over the several functions it exposes
    # ("memory" is save_memory + recall_memory), so its usage is their sum.
    def capability_usage(capability)
      names = (AgentToolbox::DEFINITIONS[capability]&.map { |definition| definition[:name].to_s } || []) + [ capability ]
      rows = detected.select { |tool| names.include?(tool[:name]) }
      return nil if rows.empty?

      timed = rows.filter_map { |row| [ row[:avg_duration_ms], row[:calls] ] if row[:avg_duration_ms] }
      weighted = timed.sum { |average, calls| average * [ calls, 1 ].max }
      samples = timed.sum { |_average, calls| [ calls, 1 ].max }

      {
        calls: rows.sum { |row| row[:calls] },
        errors: rows.sum { |row| row[:errors] },
        avg_duration_ms: samples.positive? ? (weighted / samples).round : nil,
        last_seen: rows.filter_map { |row| row[:last_seen] }.max
      }
    end

    def usage_row(tool)
      {
        calls: tool ? tool[:calls] : 0,
        errors: tool ? tool[:errors] : 0,
        avg_duration_ms: tool ? tool[:avg_duration_ms] : nil,
        last_seen: tool ? tool[:last_seen] : nil
      }
    end

    # Every function name the dashboard's own toolbox implements, so a
    # builtin never lands in the agent-defined group under its bare name.
    def dashboard_function_names
      @dashboard_function_names ||= ToolDiscovery.builtin_tools | Agent::AVAILABLE_TOOLS.to_set
    end

    # --- the agent's MCP configuration ---------------------------------

    # server key => the entry the agent stores for it. Entries are bare
    # strings or builder hashes, and an agent seeded from an older template
    # carries a top-level Hash keyed by server name — the same three shapes
    # EvaluationToolResolver tolerates.
    def configured_servers
      @configured_servers ||= configured_entries.each_with_object({}) do |entry, map|
        key = entry_key(entry)
        map[key] = entry if key.present?
      end
    end

    def configured_entries
      servers = agent.mcp_servers

      if servers.is_a?(Hash)
        servers.map { |key, value| value.respond_to?(:key?) ? value.to_h.stringify_keys.merge("key" => key.to_s) : key.to_s }
      else
        Array(servers)
      end
    end

    def entry_key(entry)
      return entry.to_s.strip.presence if entry.is_a?(String) || entry.is_a?(Symbol)
      return nil unless entry.respond_to?(:key?)

      (entry["key"] || entry[:key] || entry["name"] || entry[:name]).to_s.strip.presence
    end

    # The per-server allow-list, or nil when the entry names none — which
    # means the agent is offered every tool the server serves.
    def allowed_tools(key)
      entry = configured_servers[key]
      return nil unless entry.respond_to?(:key?)

      names = entry["tools"] || entry[:tools]
      return nil if names.nil?

      Array(names).filter_map { |tool| (tool.respond_to?(:key?) ? tool["name"] || tool[:name] : tool).to_s.presence }
    end
  end
end
