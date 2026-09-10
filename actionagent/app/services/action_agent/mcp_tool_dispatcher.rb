# frozen_string_literal: true

module ActionAgent
  # Routes a tool call to the MCP server that serves it.
  #
  # An agent names the servers it uses in +mcp_servers+, and a catalog entry
  # carries the url to reach one over HTTP. A tool the agent's servers claim is
  # called there; anything else returns nil, and the caller falls back to the
  # engine's own AgentToolbox.
  #
  # Only HTTP transports are dispatchable. A stdio server runs as a child
  # process of whatever launched it, so the dashboard has no address to call —
  # those stay listable and attributable without being callable.
  class MCPToolDispatcher
    HTTP_TRANSPORTS = %w[http streamable_http sse].freeze

    def initialize(agent)
      @agent = agent
      @resolver = EvaluationToolResolver.new(agent)
      @clients = {}
    end

    # Whether this tool belongs to one of the agent's own reachable servers.
    def dispatchable?(tool_name)
      endpoint_for(tool_name).present?
    end

    # Whether the agent names any server the dashboard can call. An agent with
    # none has nothing to execute beyond the engine's own toolbox.
    def any_reachable_server?
      resolver.declared_server_keys.any? do |key|
        entry = MCPCatalog.find(key)
        entry && entry[:transport].to_s.in?(HTTP_TRANSPORTS) && entry[:url].present?
      end
    end

    # Calls the tool on its server. Returns the same shape AgentToolbox
    # produces for a text result, or an { error: } hash when the server
    # refuses — a failing tool is a result to score, not an exception to
    # abort the run.
    #
    # @return [Hash, nil] nil when no configured server claims the tool
    def call(tool_name, arguments = {})
      endpoint = endpoint_for(tool_name)
      return nil unless endpoint

      result = client_for(endpoint).call_tool(tool_name.to_s, arguments)
      return { error: "#{tool_name} failed: #{result[:text]}" } if result[:is_error]

      { text: result[:text] }
    rescue MCPClient::Error => e
      { error: "#{tool_name} failed: #{e.message}" }
    end

    # Tool definitions from every reachable server the agent declares, in the
    # shape tool_schemas hands the provider. A server that cannot be reached
    # contributes nothing rather than failing the run — the tools it serves
    # then simply are not offered, and a scenario expecting them fails with a
    # fault naming them.
    def tool_definitions
      resolver.declared_server_keys.flat_map do |key|
        entry = MCPCatalog.find(key)
        next [] unless entry && entry[:transport].to_s.in?(HTTP_TRANSPORTS) && entry[:url].present?

        begin
          client_for(entry).list_tools
        rescue MCPClient::Error => e
          Rails.logger.warn("[MCPToolDispatcher] #{key} tools/list failed: #{e.message}")
          []
        end
      end
    end

    private

    attr_reader :agent, :resolver

    # The catalog entry for the server that serves this tool, but only when the
    # agent configured that server and the entry carries an http url. Scoping to
    # the agent's own servers is what keeps one agent's tools from reaching
    # another's.
    def endpoint_for(tool_name)
      key = resolver.server_key_for(tool_name)
      return nil if key.blank?
      return nil unless resolver.status_for(key) == EvaluationToolResolver::ENABLED

      entry = MCPCatalog.find(key)
      return nil unless entry && entry[:transport].to_s.in?(HTTP_TRANSPORTS)
      return nil if entry[:url].blank?

      entry
    end

    # One client per server for the life of this dispatcher, so a run's tool
    # calls share the MCP session the first call opens.
    def client_for(entry)
      @clients[entry[:key]] ||= MCPClient.new(url: absolute_url(entry[:url]), label: entry[:name] || entry[:key])
    end

    # A host registers its own servers with a path ("/mcp/diagnostic"), since it
    # does not know the origin it will be served under. ACTIONAGENT_MCP_ORIGIN
    # names that origin; without it a relative path is not reachable.
    def absolute_url(url)
      return url if url.to_s.start_with?("http://", "https://")

      origin = ENV["ACTIONAGENT_MCP_ORIGIN"].presence
      raise MCPClient::Error, "set ACTIONAGENT_MCP_ORIGIN to reach #{url}" if origin.blank?

      # URI.join, not File.join: a path is a URL reference, and only URI
      # resolves one against an origin that carries its own path.
      URI.join(origin, url).to_s
    rescue URI::Error => e
      raise MCPClient::Error, "ACTIONAGENT_MCP_ORIGIN #{origin.inspect} cannot reach #{url}: #{e.message}"
    end
  end
end
