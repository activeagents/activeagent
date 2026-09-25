# frozen_string_literal: true

module ActionAgent
  # Routes a tool call to the MCP server that serves it.
  #
  # An agent names the servers it uses in +mcp_servers+, and a catalog entry
  # carries the url to reach one over HTTP. A tool the agent's servers claim,
  # and that the agent's entry for that server does not switch off, is called
  # there; anything else returns nil, and the caller falls back to the engine's
  # own AgentToolbox.
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
      @listed_by = {}
    end

    # Whether this tool belongs to one of the agent's own reachable servers —
    # by its name, or because one of them listed it in the last
    # +tool_definitions+.
    def dispatchable?(tool_name)
      endpoint_for(tool_name).present?
    end

    # Whether the agent names any server the dashboard can call. An agent with
    # none has nothing to execute beyond the engine's own toolbox.
    def any_reachable_server?
      resolver.declared_server_keys.any? do |key|
        entry = catalog_entry(key)
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
    #
    # A server that fails discovery also records why, in +discovery_errors+.
    # Contributing nothing keeps the run alive, but silence is indistinguishable
    # from a server that legitimately serves no tools — and an agent offered no
    # tools answers from the model alone, which reads as a confident, fabricated
    # result rather than a transport failure (#425).
    #
    # A server entry that carries an allow-list ({key, tools: [...]}, which the
    # Tools tab saves when tools are switched off) contributes only the tools
    # it names: a tool switched off is not offered.
    #
    # Each tool offered is also remembered against the server that listed it,
    # which is how a call finds its way back (see endpoint_for).
    def tool_definitions
      @discovery_errors = {}
      @listed_by = {}

      resolver.declared_server_keys.flat_map do |key|
        entry = catalog_entry(key)
        next [] unless entry && entry[:transport].to_s.in?(HTTP_TRANSPORTS) && entry[:url].present?

        begin
          client_for(entry).list_tools.select do |tool|
            name = (tool[:name] || tool["name"]).to_s
            next false unless allowed?(key, name)

            @listed_by[name] ||= key if name.present?
            true
          end
        rescue MCPClient::Error => e
          Rails.logger.warn("[MCPToolDispatcher] #{key} tools/list failed: #{e.message}")
          @discovery_errors[key] =
            "Cannot load tools from MCP server '#{key}' (#{entry[:url]}): #{e.message}. " \
            "Check its URL, transport and credentials."
          []
        end
      end
    end

    # Why each declared server contributed no tools, keyed by server. Empty
    # until +tool_definitions+ has run, and empty after a run where every
    # declared server answered.
    #
    # @return [Hash{String => String}]
    def discovery_errors
      @discovery_errors ||= {}
    end

    # Whether every server the agent declares failed discovery. The tool-less
    # execution that follows cannot produce a meaningful result, so a caller
    # can fail loudly instead of scoring an answer the model invented.
    def all_servers_failed?
      keys = resolver.declared_server_keys.select do |key|
        entry = catalog_entry(key)
        entry && entry[:transport].to_s.in?(HTTP_TRANSPORTS) && entry[:url].present?
      end

      keys.any? && keys.all? { |key| discovery_errors.key?(key) }
    end

    private

    attr_reader :agent, :resolver, :listed_by

    # The catalog entry for the server that serves this tool, but only when the
    # agent configured that server and the entry carries an http url. Scoping to
    # the agent's own servers is what keeps one agent's tools from reaching
    # another's.
    #
    # The resolver names a server from the tool's own name: a namespace, a
    # catalog hint, or an allow-list the agent's entry carries. A bare name
    # from a server entry that lists no tools — a checkout runtime enabled as
    # "sandbox:<id>", or {key, name} as the Tools tab saves it — gives it
    # nothing to go on, and the tool the model was just offered would fall
    # through to the toolbox. So when the resolver names no server this agent
    # can call, the server that listed the tool in tool_definitions answers:
    # it is one of the agent's own, and it is where the schema the model
    # called came from.
    #
    # Either way the server's allow-list has the last word. A tool the agent's
    # entry leaves out goes to the toolbox, where the call fails, rather than
    # to a server the user switched it off on — whether the catalog hints it
    # there or the server lists it.
    def endpoint_for(tool_name)
      name = tool_name.to_s.strip

      [ resolver.server_key_for(name), listed_by[name] ].each do |key|
        entry = reachable_entry(key)
        return entry if entry && allowed?(key, name)
      end

      nil
    end

    # Whether the agent's entry for +key+ lets this tool through: it names no
    # allow-list, or its allow-list holds the tool, under its bare name or as
    # called (+mcp__<server>__<tool>+).
    def allowed?(key, tool_name)
      allowed = resolver.allowed_tools_for(key)
      return true if allowed.nil?

      allowed.include?(tool_name) || allowed.include?(ActiveAgent::Telemetry::ToolOrigin.classify(tool_name)[:tool])
    end

    # The entry for +key+ when the agent enabled that server and it has an
    # http url to call; nil otherwise.
    def reachable_entry(key)
      return nil if key.blank?
      return nil unless resolver.status_for(key) == EvaluationToolResolver::ENABLED

      entry = catalog_entry(key)
      return nil unless entry && entry[:transport].to_s.in?(HTTP_TRANSPORTS)
      return nil if entry[:url].blank?

      entry
    end

    # A catalog server, or the app runtime of a checkout sandbox the agent's
    # owner started (keys "sandbox:<session_id>"). The sandbox lookup is scoped
    # to the agent's owner, so naming another tenant's session resolves to
    # nothing.
    def catalog_entry(key)
      return MCPCatalog.find(key) unless SandboxSession.runtime_server_key?(key)

      SandboxSession.runtime_server_entry(key, owner: agent.try(:owner))
    end

    # One client per server for the life of this dispatcher, so a run's tool
    # calls share the MCP session the first call opens.
    def client_for(entry)
      @clients[entry[:key]] ||= MCPClient.new(
        url: absolute_url(entry[:url]),
        label: entry[:name] || entry[:key],
        headers: entry[:headers] || {}
      )
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
