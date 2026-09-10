# frozen_string_literal: true

module ActionAgent
  # Binds selected agent tools to enabled MCP servers. Catalog hints and
  # configured tool names establish ownership, but every offered schema comes
  # from tools/list on the server that will execute the call. The caller still
  # owns the agent.tools allowlist: discovery never adds tools to that list.
  class MCPToolBinding
    class Error < StandardError; end

    HTTP_TRANSPORTS = %w[http streamable_http streamable-http].freeze
    NAMESPACE = /\Amcp__([^\s]+?)__(.+)\z/

    def initialize(agent)
      @servers = EvaluationToolResolver.new(agent).configured_servers.map do |entry|
        catalog = MCPCatalog.find(entry[:key]) || {}
        catalog.merge(entry).merge(tools: entry[:tools] || entry[:tool_hints] || catalog[:tools])
      end.uniq { |server| server[:key] }
      @bindings = {}
      @clients = {}
      @definitions = {}
      @discovery_errors = {}
    end

    # Returns nil for a tool no enabled server owns, or a binding containing
    # its wire name, server, client and provider-neutral definition. Explicit
    # MCP claims that cannot execute raise instead of falling back to a local
    # toolbox implementation with the same name.
    def resolve(tool_name)
      name = tool_name.to_s
      return @bindings[name] if @bindings.key?(name)

      @bindings[name] = resolve_binding(name)
    end

    private

    def resolve_binding(name)
      if (namespace = NAMESPACE.match(name))
        key, wire_name = namespace.captures
        server = @servers.find { |entry| entry[:key] == key.downcase }
        raise Error, "MCP server '#{key}' is not enabled for this agent; enable it before selecting '#{name}'" unless server

        return bind(server, name, wire_name)
      end
      return nil if @servers.empty?

      claims = @servers.select { |server| declared_tool_names(server).include?(name) }
      reject_ambiguous!(name, claims)
      return bind(claims.first, name, name) if claims.one?

      # Hints are not exhaustive. Discover additional bare names on enabled
      # HTTP servers, while leaving unrelated stdio servers alone. Selecting
      # a hinted or namespaced stdio tool above still raises an actionable
      # unsupported-transport error rather than executing a toolbox fallback.
      matches = @servers.select do |server|
        discoverable?(server) && definitions_for(server).any? { |tool| tool["name"] == name }
      end
      reject_ambiguous!(name, matches)
      bind(matches.first, name, name) if matches.one?
    end

    def declared_tool_names(server)
      Array(server[:tools]).filter_map do |tool|
        name = tool.respond_to?(:key?) ? tool["name"] || tool[:name] : tool
        next if name.to_s.empty?

        if (namespace = NAMESPACE.match(name.to_s))
          namespace[2] if namespace[1].downcase == server[:key]
        else
          name.to_s
        end
      end
    end

    def discoverable?(server)
      transport = server[:transport].to_s.downcase
      HTTP_TRANSPORTS.include?(transport) || (transport.empty? && server[:url].present?)
    end

    def reject_ambiguous!(name, servers)
      return if servers.size < 2

      keys = servers.map { |server| server[:key] }.join(", ")
      raise Error, "MCP tool '#{name}' is ambiguous across enabled servers: #{keys}; select mcp__SERVER__#{name}"
    end

    def bind(server, name, wire_name)
      tool = definitions_for(server).find { |definition| definition["name"] == wire_name }
      unless tool
        raise Error, "MCP server '#{server[:key]}' does not offer selected tool '#{wire_name}'; check tools/list or update the agent's tools"
      end
      unless tool["inputSchema"].is_a?(Hash)
        raise Error, "MCP server '#{server[:key]}' returned no valid inputSchema for '#{wire_name}'; fix its tools/list response"
      end

      {
        name: wire_name,
        server: server[:key],
        client: @clients.fetch(server[:key]),
        definition: {
          name: name,
          description: tool["description"].presence || "Call #{wire_name} on MCP server '#{server[:key]}'",
          parameters: tool["inputSchema"]
        }
      }
    end

    def definitions_for(server)
      key = server[:key]
      raise @discovery_errors[key] if @discovery_errors.key?(key)
      return @definitions[key] if @definitions.key?(key)

      client = @clients[key] ||= MCPClient.new(url: server[:url], transport: server[:transport].presence || "http")
      tools = client.list_tools
      unless tools.is_a?(Array) && tools.all? { |tool| tool.is_a?(Hash) }
        raise Error, "tools/list must return an array of tool definitions"
      end
      @definitions[key] = tools.map(&:stringify_keys)
    rescue StandardError => error
      @discovery_errors[key] ||= Error.new(
        "Cannot load tools from MCP server '#{key}': #{error.message}. Check its MCP server URL and transport"
      )
      raise @discovery_errors[key]
    end
  end
end
