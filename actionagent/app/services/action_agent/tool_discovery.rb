# frozen_string_literal: true

module ActionAgent
  # Builds the dashboard's tool and MCP-server inventory by reading what
  # agents actually called, rather than what someone remembered to register.
  #
  # Four record sources are merged, because each one sees a different slice
  # of the same traffic:
  #
  # * **The offered tool roster** — the tools array in each generation
  #   request, recorded on the prompt span as +prompt.input.tools+ and on
  #   each solid_agent generation as +provenance["tools"]+. The only source
  #   that sees a tool the model was given and never called, and the only
  #   one carrying descriptions and parameter names.
  # * **Telemetry tool spans** — the only source for agents running in a
  #   host app and reporting in over the wire, and where timing and error
  #   rates come from.
  # * **solid_agent generations** (+agent_generations.tool_calls+) — every
  #   tool call the model *requested*, including ones that never produced a
  #   span because the run died first.
  # * **solid_agent messages** (+agent_messages+ with +role: "tool"+) — the
  #   results that came back, which is where a tool's arguments survive even
  #   when telemetry is disabled.
  #
  # Counting a tool once per source would multiply-count a dashboard-executed
  # run, which writes all four. So each source feeds a distinct counter
  # (+calls+, +requested+, +results+) and +calls+ falls back to the largest
  # observed count when telemetry is absent — a self-hosted install with
  # telemetry off still gets real numbers instead of zeros.
  #
  # MCP attribution comes from ActiveAgent::Telemetry::ToolOrigin (the
  # +mcp__server__tool+ convention, tagged onto spans at instrumentation
  # time), then MCPCatalog's hints for bare tool names, then the tool is
  # treated as a method the agent class defines.
  #
  # Scopes are passed in rather than derived, so the caller's ownership
  # rules (single-user, per-user, or multi-tenant) decide what is visible.
  class ToolDiscovery
    DEFAULT_WINDOW_HOURS = 24 * 7
    MAX_WINDOW_HOURS = 24 * 90

    # The inventory is derived by reading records rather than by maintaining
    # a summary table, and the window alone does not bound how many rows a
    # busy account has in it — a 90-day window over a high-traffic workspace
    # is millions. Scans stop here and say so rather than pinning a worker
    # for the length of a request. A precomputed summary is the real answer;
    # this keeps the page responsive until there is one.
    MAX_SCAN_ROWS = 20_000

    # Origin values, matching the framework's ToolOrigin plus the
    # dashboard-only "builtin" bucket for AgentToolbox's executable tools.
    ORIGIN_MCP = "mcp"
    ORIGIN_BUILTIN = "builtin"
    ORIGIN_AGENT = "agent"

    attr_reader :traces, :agents, :window_hours, :since

    # @param traces [ActiveRecord::Relation] the traces the caller may read
    # @param agents [ActiveRecord::Relation] the agents the caller may reach
    # @param hours [Integer] how far back to look
    def initialize(traces:, agents:, hours: DEFAULT_WINDOW_HOURS)
      @traces = traces
      @agents = agents
      @window_hours = hours.to_i.clamp(1, MAX_WINDOW_HOURS)
      @since = @window_hours.hours.ago
    end

    # The full inventory: every tool seen in the window, plus the MCP servers
    # they roll up into and the configured-but-unused surface.
    #
    # @return [Hash]
    def inventory
      tools = detected_tools
      {
        tools: tools,
        servers: servers_for(tools),
        summary: summary_for(tools),
        window_hours: window_hours,
        sources: source_availability
      }
    end

    # Detected tools, most-used first.
    #
    # @return [Array<Hash>]
    def detected_tools
      index = {}

      merge_declared_tools(index)
      merge_trace_tools(index)
      merge_generation_tools(index)
      merge_message_tools(index)
      merge_configured_tools(index)

      index.values.map { |entry| finalize(entry) }.sort_by { |tool| [ -tool[:calls], tool[:name] ] }
    end

    # MCP servers, detected traffic joined against the catalog so unused
    # defaults are still listed (as +status: "available"+).
    #
    # @return [Array<Hash>]
    def servers(tools = detected_tools)
      servers_for(tools)
    end

    # Tools AgentToolbox implements inside the dashboard. Neither MCP nor
    # agent-defined — the engine runs them — so they get their own origin
    # rather than being mislabeled as methods on the agent class. Resolved
    # lazily: referencing an autoloaded constant while this class is being
    # defined would bind whatever happened to be loaded first.
    def self.builtin_tools
      @builtin_tools ||= AgentToolbox::DEFINITIONS.values.flatten
        .map { |definition| definition[:name].to_s }.to_set
    end

    private

    # --- sources -------------------------------------------------------

    # The roster each generation request OFFERED the provider, from the
    # solid_agent side. The trace side is read in merge_trace_tools, which
    # already has each trace loaded.
    def merge_declared_tools(index)
      declared_generations.each do |generation|
        provenance = generation.provenance
        next unless provenance.is_a?(Hash)

        Array(provenance["tools"]).each do |declared|
          next unless declared.is_a?(Hash)

          absorb_declaration(
            index,
            {
              name: declared["name"],
              description: declared["description"],
              parameters: Array(declared["parameters"])
            },
            agent: provenance["agent_class"],
            source: "provenance",
            at: generation.created_at
          )
        end
      end
    end

    def absorb_declaration(index, declared, agent:, source:, at:)
      entry = entry_for(index, declared[:name])
      return if entry.nil?

      entry[:declared] = true
      entry[:description] ||= declared[:description].presence
      entry[:parameters] = declared[:parameters] if entry[:parameters].blank? && declared[:parameters].present?
      entry[:agents] << agent if agent.present?
      entry[:sources] << source
      apply_origin(entry, **classify(declared[:name]))
      touch(entry, at)
    end

    # Tool spans from telemetry. Read in Ruby rather than SQL because the
    # spans are a nested JSON array; traversing it in SQL would be a
    # PostgreSQL-only query, and the dashboard runs on SQLite and MySQL too.
    def merge_trace_tools(index)
      scanned = 0

      traces_scope.find_each(batch_size: 200) do |trace|
        scanned += 1
        break if scanned > MAX_SCAN_ROWS

        agent_label = trace.agent_class.presence

        # Same pass, two readings of one trace: what the request offered,
        # and what the model then called.
        trace.declared_tools.each do |declared|
          absorb_declaration(index, declared, agent: agent_label, source: "request", at: trace.timestamp)
        end

        trace.tool_usage.each do |usage|
          entry = entry_for(index, usage[:name])
          next if entry.nil?

          entry[:calls] += 1
          entry[:errors] += 1 if usage[:status].to_s == "ERROR" || usage[:error].present?
          if (duration = usage[:duration_ms])
            entry[:duration_total] += duration.to_f
            entry[:duration_samples] += 1
          end
          entry[:agents] << agent_label if agent_label
          entry[:sources] << "telemetry"
          entry[:sample_arguments] ||= usage[:arguments].presence
          entry[:last_error] ||= usage[:error].presence
          apply_origin(entry, **resolve_origin(usage[:name], usage[:mcp_server]))
          touch(entry, trace.timestamp)
        end
      end

      warn_if_capped(scanned, "traces")
    end

    # A capped scan is a partial inventory, so it is never silent.
    def warn_if_capped(count, what)
      return if count < MAX_SCAN_ROWS

      Rails.logger.warn(
        "[ActionAgent] tool discovery stopped at #{MAX_SCAN_ROWS} #{what}; " \
        "the inventory for this window may be incomplete"
      )
    end

    # Tool calls the model asked for, recorded on each solid_agent
    # generation. Selected columns only — raw_response on these rows can be
    # large and nothing here reads it.
    def merge_generation_tools(index)
      generations_scope.find_each(batch_size: 500) do |generation|
        Array(generation.tool_calls).each do |call|
          name = call_name(call)
          entry = entry_for(index, name)
          next if entry.nil?

          entry[:requested] += 1
          entry[:sources] << "generations"
          entry[:sample_arguments] ||= stringify_arguments(call["arguments"] || call[:arguments])
          apply_origin(entry, **classify(name))
          touch(entry, generation.created_at)
        end
      end
    end

    # Tool results persisted as conversation messages. These carry the
    # arguments a tool was actually invoked with, which telemetry truncates.
    def merge_message_tools(index)
      messages_scope.find_each(batch_size: 500) do |message|
        entry = entry_for(index, message.tool_name)
        next if entry.nil?

        entry[:results] += 1
        entry[:sources] << "messages"
        entry[:sample_arguments] ||= stringify_arguments(message.tool_arguments)
        apply_origin(entry, **classify(message.tool_name))
        touch(entry, message.created_at)
      end
    end

    # Tools an agent has enabled in the builder but that have no traffic in
    # the window. Listing them keeps the view honest: "configured, never
    # called" is a real and useful state, and it's the difference between a
    # tool that is broken and one that simply isn't wired up yet.
    def merge_configured_tools(index)
      agents.find_each(batch_size: 200) do |agent|
        Array(agent.tools).each do |tool_name|
          # An agent enables a capability ("playwright"); the model calls
          # the functions that capability exposes. Expand to the real tool
          # names so configured and detected rows describe the same things.
          expand_configured(tool_name).each do |name|
            entry = entry_for(index, name)
            next if entry.nil?

            entry[:configured_by] << agent.name
            apply_origin(entry, **classify(name))
          end
        end

        Array(agent.mcp_servers).each do |server|
          key = mcp_server_key(server)
          next if key.blank?

          configured_servers[key] << agent.name
        end
      end
    end

    # --- scopes --------------------------------------------------------

    def traces_scope
      traces.where(timestamp: since..)
    end

    def generations_scope
      AgentGeneration
        .select(:id, :agent_context_id, :tool_calls, :created_at)
        .where(agent_context_id: context_ids, created_at: since..)
        .where(AgentGeneration.json_array_not_empty_sql(:tool_calls))
    end

    def messages_scope
      AgentMessage
        .select(:id, :agent_context_id, :tool_name, :tool_arguments, :created_at)
        .where(agent_context_id: context_ids, created_at: since.., role: "tool")
        .where.not(tool_name: nil)
    end

    # Generations whose provenance carries the offered tool roster.
    #
    # PostgreSQL can ask that of the column directly; everywhere else the
    # rows are read and filtered in Ruby, which is why this returns records
    # rather than a relation. The window already bounds how many.
    def declared_generations
      @declared_generations ||= begin
        scope = AgentGeneration
          .select(:id, :agent_context_id, :provenance, :created_at)
          .where(agent_context_id: context_ids, created_at: since..)

        rows =
          if AgentGeneration.postgres?
            scope.where(Arel.sql("jsonb_exists(provenance, 'tools')")).limit(MAX_SCAN_ROWS).to_a
          else
            # No portable way to ask this of the column, so the rows are read
            # and filtered in Ruby. Capped, because the window alone does not
            # bound how many a busy account has.
            scope.limit(MAX_SCAN_ROWS).to_a.select do |generation|
              generation.provenance.is_a?(Hash) && generation.provenance.key?("tools")
            end
          end

        warn_if_capped(rows.length, "provenance generations")
        rows
      end
    end

    # Whether any generation in the window carries an offered tool roster,
    # asked as cheaply as the adapter allows. Kept separate from
    # declared_generations so source_availability never materialises rows
    # just to decide a boolean.
    def declared_generations?
      scope = AgentGeneration.where(agent_context_id: context_ids, created_at: since..)

      if AgentGeneration.postgres?
        scope.where(Arel.sql("jsonb_exists(provenance, 'tools')")).limit(1).exists?
      else
        declared_generations.any?
      end
    end

    def context_ids
      @context_ids ||= AgentContext.for_agents(agents).pluck(:id)
    end

    # Which record sources actually had rows in the window. The view uses
    # this to explain an empty inventory ("no telemetry reported yet")
    # instead of showing a bare zero.
    def source_availability
      {
        telemetry: traces_scope.limit(1).exists?,
        generations: generations_scope.limit(1).exists?,
        messages: messages_scope.limit(1).exists?,
        declared: declared_generations?
      }
    end

    # --- aggregation ---------------------------------------------------

    def entry_for(index, name)
      name = name.to_s.strip
      return nil if name.blank?

      index[name] ||= {
        name: name,
        calls: 0,
        requested: 0,
        results: 0,
        errors: 0,
        duration_total: 0.0,
        duration_samples: 0,
        agents: Set.new,
        sources: Set.new,
        configured_by: Set.new,
        origin: nil,
        mcp_server: nil,
        sample_arguments: nil,
        last_error: nil,
        declared: false,
        description: nil,
        parameters: [],
        first_seen: nil,
        last_seen: nil
      }
    end

    # An explicit MCP server always wins: it came from the trace itself. A
    # catalog hint only fills a gap, and never downgrades an already-known
    # origin (a tool seen once as namespaced stays MCP even if a later bare
    # call for the same name arrives).
    def apply_origin(entry, origin:, server: nil)
      if server.present?
        entry[:mcp_server] ||= server
        entry[:origin] = ORIGIN_MCP
        return
      end

      entry[:origin] ||= origin
    end

    # Origin for a tool a trace reported. A server named by the trace is
    # taken at face value; anything else is re-classified here, because a
    # trace can only tell MCP from not-MCP and knows nothing about the
    # dashboard's own toolbox.
    def resolve_origin(name, explicit_server)
      return { origin: ORIGIN_MCP, server: explicit_server } if explicit_server.present?

      classify(name)
    end

    def classify(name)
      name = name.to_s
      classification = ActiveAgent::Telemetry::ToolOrigin.classify(name)
      return { origin: ORIGIN_MCP, server: classification[:server] } if classification[:server].present?

      if (hinted = MCPCatalog.server_for_tool(name))
        # A catalog hint is weaker evidence than a namespaced name: the tool
        # is *probably* this server's, but a builtin of the same name is the
        # dashboard's own implementation, so builtins win the tie.
        return { origin: ORIGIN_BUILTIN, server: nil } if builtin?(name)

        return { origin: ORIGIN_MCP, server: hinted }
      end

      return { origin: ORIGIN_BUILTIN, server: nil } if builtin?(name)

      { origin: ORIGIN_AGENT, server: nil }
    end

    def builtin?(name)
      self.class.builtin_tools.include?(name)
    end

    def touch(entry, timestamp)
      return if timestamp.blank?

      entry[:first_seen] = timestamp if entry[:first_seen].nil? || timestamp < entry[:first_seen]
      entry[:last_seen] = timestamp if entry[:last_seen].nil? || timestamp > entry[:last_seen]
    end

    def finalize(entry)
      # Telemetry is the authoritative call count, but an install with
      # telemetry disabled would otherwise report every tool as 0 calls
      # while plainly showing results. Fall back to the strongest signal.
      calls = [ entry[:calls], entry[:requested], entry[:results] ].max
      origin = entry[:origin] || ORIGIN_AGENT

      {
        name: entry[:name],
        base_name: base_name(entry[:name]),
        origin: origin,
        mcp_server: entry[:mcp_server],
        source_label: source_label(origin, entry[:mcp_server]),
        description: entry[:description],
        parameters: entry[:parameters],
        # Offered to the model in a generation request body, as opposed to
        # only ever inferred from a call that happened.
        declared: entry[:declared],
        calls: calls,
        traced_calls: entry[:calls],
        requested: entry[:requested],
        results: entry[:results],
        errors: entry[:errors],
        error_rate: calls.positive? ? (entry[:errors].to_f / calls * 100).round(1) : 0.0,
        avg_duration_ms: entry[:duration_samples].positive? ? (entry[:duration_total] / entry[:duration_samples]).round(0) : nil,
        agents: entry[:agents].to_a.sort,
        configured_by: entry[:configured_by].to_a.sort,
        detected_from: entry[:sources].to_a.sort,
        # Wired up but never called — the state that tells you a tool is
        # available and simply unused, rather than missing. A declared tool
        # counts here too: the model was offered it and never reached for it.
        unused: calls.zero? && (entry[:configured_by].any? || entry[:declared]),
        sample_arguments: entry[:sample_arguments],
        last_error: entry[:last_error],
        first_seen: entry[:first_seen]&.iso8601,
        last_seen: entry[:last_seen]&.iso8601
      }
    end

    def base_name(name)
      ActiveAgent::Telemetry::ToolOrigin.classify(name)[:tool]
    end

    def source_label(origin, server)
      case origin
      when ORIGIN_MCP then server.present? ? "MCP · #{MCPCatalog.display_name(server)}" : "MCP"
      when ORIGIN_BUILTIN then "Dashboard toolbox"
      else "Agent-defined"
      end
    end

    # --- servers -------------------------------------------------------

    # Rolls detected tools up into servers, then unions with the catalog so
    # the view lists defaults this install hasn't connected yet.
    def servers_for(tools)
      detected = Hash.new { |hash, key| hash[key] = { tools: [], calls: 0, errors: 0, last_seen: nil } }

      tools.each do |tool|
        key = tool[:mcp_server]
        next if key.blank?

        bucket = detected[key]
        bucket[:tools] << tool
        bucket[:calls] += tool[:calls]
        bucket[:errors] += tool[:errors]
        if tool[:last_seen].present? && (bucket[:last_seen].nil? || tool[:last_seen] > bucket[:last_seen])
          bucket[:last_seen] = tool[:last_seen]
        end
      end

      keys = (MCPCatalog::BY_KEY.keys + detected.keys + configured_servers.keys).uniq

      # detected has a default block that would materialize a bucket on
      # lookup, so unseen servers are passed through as an explicit nil.
      keys.map { |key| server_row(key, (detected[key] if detected.key?(key))) }
          .sort_by { |server| [ -server[:calls], server[:status] == "available" ? 1 : 0, server[:name].downcase ] }
    end

    def server_row(key, bucket)
      catalog = MCPCatalog.find(key)
      configured = configured_servers[key].to_a.sort
      calls = bucket ? bucket[:calls] : 0

      {
        key: key,
        name: catalog ? catalog[:name] : key,
        description: catalog&.fetch(:description, nil),
        transport: catalog&.fetch(:transport, nil),
        command: catalog&.fetch(:command, nil),
        url: catalog&.fetch(:url, nil),
        categories: catalog ? catalog[:categories] : [],
        docs_url: catalog&.fetch(:docs_url, nil),
        first_party: catalog ? catalog[:first_party] : false,
        requires_credentials: catalog ? catalog[:requires_credentials] : [],
        launchable: catalog ? catalog[:sandbox] : false,
        sandbox_type: catalog&.fetch(:sandbox_type, nil),
        # Catalog membership is what "known" means — a server detected purely
        # from traffic is real but undocumented here, and the view says so.
        known: !catalog.nil?,
        status: server_status(calls, configured, catalog),
        calls: calls,
        errors: bucket ? bucket[:errors] : 0,
        tool_count: bucket ? bucket[:tools].size : 0,
        tools: bucket ? bucket[:tools].map { |tool| tool[:base_name] }.uniq.sort : catalog_tool_names(catalog),
        agents: bucket ? bucket[:tools].flat_map { |tool| tool[:agents] }.uniq.sort : [],
        configured_by: configured,
        last_seen: bucket ? bucket[:last_seen] : nil
      }
    end

    # "active"    — traffic in the window
    # "configured"— an agent declares it, but nothing called it yet
    # "available" — a catalog default this install has never used
    def server_status(calls, configured, catalog)
      return "active" if calls.positive?
      return "configured" if configured.any?
      return "available" if catalog

      "idle"
    end

    def catalog_tool_names(catalog)
      catalog ? catalog[:tools] : []
    end

    def configured_servers
      @configured_servers ||= Hash.new { |hash, key| hash[key] = Set.new }
    end

    # An agent's mcp_servers entries are free-form: a bare string name, or a
    # hash from the builder ({"name" => "playwright", "url" => ...}).
    def mcp_server_key(server)
      return server.to_s.strip if server.is_a?(String)
      return nil unless server.respond_to?(:[])

      (server["key"] || server[:key] || server["name"] || server[:name]).to_s.strip.presence
    end

    # --- summary -------------------------------------------------------

    def summary_for(tools)
      called = tools.select { |tool| tool[:calls].positive? }
      total_calls = called.sum { |tool| tool[:calls] }
      total_errors = called.sum { |tool| tool[:errors] }
      timed = called.filter_map { |tool| tool[:avg_duration_ms] }

      {
        total_tools: tools.size,
        active_tools: called.size,
        unused_tools: tools.count { |tool| tool[:unused] },
        declared_tools: tools.count { |tool| tool[:declared] },
        mcp_tools: tools.count { |tool| tool[:origin] == ORIGIN_MCP },
        total_calls: total_calls,
        total_errors: total_errors,
        error_rate: total_calls.positive? ? (total_errors.to_f / total_calls * 100).round(1) : 0.0,
        avg_duration_ms: timed.any? ? (timed.sum / timed.size).round(0) : nil,
        mcp_servers_active: tools.filter_map { |tool| tool[:mcp_server] if tool[:calls].positive? }.uniq.size
      }
    end

    def call_name(call)
      return nil unless call.respond_to?(:[])

      (call["name"] || call[:name] || call.dig("function", "name")).to_s.presence
    end

    def stringify_arguments(arguments)
      return nil if arguments.blank?
      return arguments if arguments.is_a?(String)

      arguments.to_json
    rescue StandardError
      nil
    end

    # A builder capability maps to the function names it exposes; anything
    # not in the toolbox is passed through under its own name.
    def expand_configured(capability)
      definitions = AgentToolbox::DEFINITIONS[capability.to_s]
      return [ capability.to_s ] if definitions.blank?

      definitions.map { |definition| definition[:name].to_s }
    end
  end
end
