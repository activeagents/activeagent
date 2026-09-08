# frozen_string_literal: true

module ActionAgent
  # Names the MCP server behind a tool an evaluation run needs, for the
  # report's fix items (ActiveAgent::Evals::Report#fix_items): a scenario
  # that expected +search_slots+ and never got it is fixed by enabling the
  # server that serves it, and the item can only say so — and deep-link to
  # MCP Services — when something here can name that server.
  #
  # Resolution follows the order ToolDiscovery attributes traffic in: an
  # explicit +mcp__server__tool+ namespace wins because the name said so,
  # then MCPCatalog's hints for the bare names of well-known servers, then
  # the servers the agent itself declares in +mcp_servers+ when one of them
  # lists the tool. Nothing here reads telemetry: the resolver runs inside
  # the request that serializes a run, and every lookup is a constant or a
  # single agent attribute.
  #
  # The status is what the fix item's action turns on:
  #
  #   "enabled"   — the agent's mcp_servers configuration names the server
  #   "available" — the catalog (built-in or ActionAgent.mcp_catalog) knows
  #                 the server and the agent has not enabled it
  #   nil         — the namespace named a server nothing here knows; the
  #                 report renders that as "unknown"
  #
  # @example
  #   resolver = EvaluationToolResolver.new(agent)
  #   resolver.call("browser_navigate")
  #   # => { "key" => "playwright", "name" => "Playwright", "status" => "available" }
  class EvaluationToolResolver
    ENABLED = "enabled"
    AVAILABLE = "available"

    attr_reader :agent

    # @param agent [ActionAgent::Agent, nil] the agent the run evaluated; nil
    #   resolves against the catalog alone
    def initialize(agent)
      @agent = agent
    end

    # The Report's +tool_resolver+ contract.
    #
    # @param tool_name [String, Symbol] a tool name as a scenario expected it
    #   or the model called it
    # @return [Hash, nil] +{ "key", "name", "status" }+, or nil when no
    #   server can be named for the tool
    def call(tool_name)
      key = server_key_for(tool_name)
      return nil if key.nil?

      { "key" => key, "name" => display_name_for(key), "status" => status_for(key) }
    end

    # @param tool_name [String, Symbol]
    # @return [String, nil] the server key the tool belongs to
    def server_key_for(tool_name)
      name = tool_name.to_s.strip
      return nil if name.blank?

      ActiveAgent::Telemetry::ToolOrigin.server_for(name).presence ||
        MCPCatalog.server_for_tool(name).presence ||
        configured_tools[name]
    end

    # @param key [String] a server key
    # @return [String, nil] ENABLED, AVAILABLE, or nil when unknown
    def status_for(key)
      return ENABLED if configured_keys.include?(normalize(key))
      return AVAILABLE if MCPCatalog.find(key)

      nil
    end

    private

    # The catalog's name when it has one; otherwise the name the agent's
    # own configuration gives the server, and the key as a last resort
    # (which is what MCPCatalog.display_name falls back to as well).
    def display_name_for(key)
      return MCPCatalog.display_name(key) if MCPCatalog.find(key)

      configured_names[normalize(key)] || MCPCatalog.display_name(key)
    end

    # Server keys the agent declares, normalized for comparison.
    def configured_keys
      @configured_keys ||= configured_entries.filter_map { |entry| normalize(entry_key(entry)) }.to_set
    end

    # normalized key => the display name a configured hash entry carries
    # alongside its key ({"key" => "sparkle", "name" => "Sparkle Match"}).
    def configured_names
      @configured_names ||= configured_entries.each_with_object({}) do |entry, map|
        next unless entry.respond_to?(:key?)

        key = normalize(entry_key(entry))
        name = (entry["name"] || entry[:name]).to_s.strip
        next if key.nil? || name.blank? || name.downcase == key

        map[key] ||= name
      end
    end

    # bare tool name => server key, from configured entries that list the
    # tools they serve ({"name" => "sparkle", "tools" => ["search_slots"]}),
    # in the catalog's own +tool_hints+ spelling or as tool hashes.
    def configured_tools
      @configured_tools ||= configured_entries.each_with_object({}) do |entry, map|
        next unless entry.respond_to?(:key?)

        key = entry_key(entry)
        next if key.nil?

        Array(entry["tools"] || entry[:tools] || entry["tool_hints"] || entry[:tool_hints]).each do |tool|
          name = (tool.respond_to?(:key?) ? tool["name"] || tool[:name] : tool).to_s.strip
          map[name] ||= key unless name.blank?
        end
      end
    end

    # The agent's mcp_servers as a list of entries. Agents store an Array of
    # bare names or builder hashes, but an agent seeded from an older
    # template carries a top-level Hash keyed by server name
    # ({"playwright" => {"command" => ...}}) — the same shape ToolDiscovery
    # tolerates — whose values become entries carrying that key.
    def configured_entries
      @configured_entries ||= begin
        servers = agent&.mcp_servers

        if servers.is_a?(Hash)
          servers.map do |key, value|
            value.respond_to?(:key?) ? value.to_h.stringify_keys.merge("key" => key.to_s) : key.to_s
          end
        else
          Array(servers)
        end
      end
    end

    # An entry names its server as a bare string, or under +key+ or +name+
    # in a builder hash. Anything else (a stray Array, a number) is skipped.
    def entry_key(entry)
      return entry.to_s.strip.presence if entry.is_a?(String) || entry.is_a?(Symbol)
      return nil unless entry.respond_to?(:key?)

      (entry["key"] || entry[:key] || entry["name"] || entry[:name]).to_s.strip.presence
    end

    def normalize(key)
      key.to_s.strip.downcase.presence
    end
  end
end
