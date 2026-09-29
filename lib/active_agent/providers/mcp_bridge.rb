# frozen_string_literal: true

module ActiveAgent
  module Providers
    # Runs MCP servers from the client side.
    #
    # Declaring `mcps:` is normally passthrough: the declaration is translated
    # into the provider's own `mcp_servers` parameter and the provider runs the
    # tool loop. That works only where the provider implements MCP. DeepSeek does
    # not — it ignores `mcp_servers`, returns 200, and answers without the
    # server's data, so the failure reads as a poor answer rather than as a
    # configuration error.
    #
    # This bridge closes that gap without the provider's help. It connects to
    # each declared server, lists the tools it offers, merges them with whatever
    # tools the caller declared, and answers tool calls on the server that owns
    # them. The provider's tool loop is untouched: it is handed tools it can call
    # and receives results, which is all it ever needed.
    #
    # The `mcp` gem is loaded only when a bridge is built, so it stays an
    # optional dependency for anyone who does not declare `mcps:` against a
    # client-side provider.
    #
    # @see ActiveAgent::Providers::MCPServing#mcp_resolved_context
    class MCPBridge
      # Raised when a bridge is built without the `mcp` gem installed.
      class MissingGemError < LoadError; end

      # Raised when two tools would share a name. The model has no way to say
      # which it meant, so this is refused rather than resolved by guessing.
      class DuplicateToolError < StandardError; end

      # Schema handed to a tool that declares none. Providers expect an object
      # schema, and MCP permits omitting it.
      EMPTY_SCHEMA = { type: "object", properties: {} }.freeze

      # A declared server, paired with the client connected to it.
      Server = Struct.new(:name, :declaration, :client, keyword_init: true)

      # @param servers [Array<Hash>, Hash, nil] common-format `mcps:`
      #   declarations. A single Hash is accepted as a one-server list, because
      #   `Array(some_hash)` would split it into pairs.
      def initialize(servers)
        @declarations = normalize_all(servers)
        @tools        = nil
        @ownership    = {}
      end

      # @return [Boolean] whether no servers were declared
      def empty? = @declarations.empty?

      # Every tool the declared servers offer, in the common format.
      #
      # @return [Array<Hash>]
      def tools
        discover if @tools.nil?
        @tools
      end

      # @param name [String, Symbol] tool name
      # @return [Boolean] whether a declared server provides this tool
      def owns?(name)
        tools

        @ownership.key?(name.to_s)
      end

      # The caller's tools followed by the servers' tools.
      #
      # @param declared [Array<Hash>, nil] tools the caller declared
      # @return [Array<Hash>]
      # @raise [DuplicateToolError] when a declared tool and a server tool share
      #   a name
      def merge_tools(declared)
        declared = Array(declared)
        taken    = declared.map { |tool| tool_name(tool) }

        tools.each do |tool|
          next unless taken.include?(tool[:name])

          fail DuplicateToolError,
               "A tool named #{tool[:name].inspect} is declared by the agent and also offered by an MCP " \
               "server, so the model cannot choose between them. Rename one, or restrict the server with " \
               "`allowed_tools:`."
        end

        declared + tools
      end

      # Invokes a tool on the server that owns it.
      #
      # @param name [String, Symbol] tool name
      # @param kwargs [Hash] tool arguments
      # @return [String, Hash] the tool's result
      # @raise [ArgumentError] when no server provides the tool
      def call(name, **kwargs)
        self.class.load_mcp!

        tools # populates ownership

        server = @ownership.fetch(name.to_s) do
          fail ArgumentError, "No declared MCP server provides a tool named #{name.to_s.inspect}."
        end

        flatten_result(server.client.call_tool(name: name.to_s, arguments: kwargs))
      end

      # Loads the `mcp` gem, explaining the dependency if it is absent.
      #
      # @return [void]
      # @raise [MissingGemError]
      def self.load_mcp!
        require "mcp"
      rescue LoadError => e
        raise MissingGemError,
              "Using `mcps:` with a provider that has no server-side MCP requires the 'mcp' gem. " \
              "Add `gem \"mcp\"` to your Gemfile and run `bundle install`. (#{e.message})"
      end

      private

      # Connects to each server once and records which of them owns each tool.
      #
      # @return [void]
      def discover
        @tools     = []
        @ownership = {}

        @declarations.each do |declaration|
          server = connect(declaration)

          server_tools(server).each do |tool|
            existing = @ownership[tool[:name]]

            if existing
              fail DuplicateToolError,
                   "Two declared MCP servers offer a tool named #{tool[:name].inspect}: " \
                   "#{existing.name.inspect} and #{server.name.inspect}. The model cannot choose between " \
                   "them, so rename one or restrict it with `allowed_tools:`."
            end

            @ownership[tool[:name]] = server
            @tools << tool
          end
        end
      end

      # Connects a client to one declared server.
      #
      # @param declaration [Hash]
      # @return [Server]
      def connect(declaration)
        self.class.load_mcp!

        client = MCP::Client.new(transport: transport_for(declaration))
        client.connect

        Server.new(name: declaration[:name], declaration:, client:)
      end

      # @param declaration [Hash]
      # @return [Object] an MCP transport
      def transport_for(declaration)
        if declaration[:url]
          MCP::Client::HTTP.new(url: declaration[:url], headers: headers_for(declaration))
        elsif declaration[:command]
          MCP::Client::Stdio.new(
            command: declaration[:command],
            args:    Array(declaration[:args]),
            env:     declaration[:env]
          )
        else
          fail ArgumentError,
               "An entry in `mcps:` needs either a `url:` or a `command:` to connect to, " \
               "got #{declaration.inspect}."
        end
      end

      # @param declaration [Hash]
      # @return [Hash] request headers for the server
      def headers_for(declaration)
        token = declaration[:authorization] || declaration[:authorization_token]

        token.present? ? { "Authorization" => "Bearer #{token}" } : {}
      end

      # One server's tools, in the common format.
      #
      # @param server [Server]
      # @return [Array<Hash>]
      def server_tools(server)
        allowed = Array(server.declaration[:allowed_tools]).map { |tool| tool_name(tool) }
        allowed = nil if allowed.empty?

        server.client.tools.filter_map do |tool|
          name = tool.name.to_s
          next if allowed && !allowed.include?(name)

          {
            name:        name,
            description: tool.description,
            parameters:  tool.input_schema || EMPTY_SCHEMA
          }.compact
        end
      end

      # Reduces an MCP tool result to something a provider can hand back to the
      # model. Structured content is preferred when the server sends it, since
      # it is the machine-readable form; otherwise the text blocks are joined.
      #
      # `MCP::Client#call_tool` returns the whole JSON-RPC envelope, so the tool
      # result sits one level down. That is unwrapped first — keyed off the
      # envelope's own marker rather than the presence of `result`, which a tool
      # is free to use as a field name.
      #
      # @param result [Object]
      # @return [String, Hash]
      def flatten_result(result)
        result = result.to_h if result.respond_to?(:to_h) && !result.is_a?(Hash)
        return result unless result.is_a?(Hash)

        if result.key?(:jsonrpc) || result.key?("jsonrpc")
          error = result[:error] || result["error"]
          return error_message(error) if error

          result = result[:result] || result["result"] || {}
        end

        structured = result[:structuredContent] || result["structuredContent"]
        return structured if structured

        blocks = result[:content] || result["content"]
        return "" if blocks.nil?

        Array(blocks).filter_map do |block|
          block = block.to_h if block.respond_to?(:to_h) && !block.is_a?(Hash)

          block[:text] || block["text"] if block.is_a?(Hash)
        end.join("\n")
      end

      # Renders a JSON-RPC error for the model. It is returned as tool content
      # rather than raised: the model can often recover from a bad argument,
      # and a raise here would surface as a failed generation instead.
      #
      # @param error [Hash, String, nil]
      # @return [String]
      def error_message(error)
        case error
        when Hash then (error[:message] || error["message"] || error.inspect).to_s
        when nil  then "The MCP server returned an empty error."
        else error.to_s
        end
      end

      # @param servers [Array<Hash>, Hash, nil]
      # @return [Array<Hash>]
      def normalize_all(servers)
        return [] if servers.nil?
        return [ normalize(servers) ] if servers.is_a?(Hash)

        Array(servers).map { |server| normalize(server) }
      end

      # @param server [Hash]
      # @return [Hash] declaration with symbolized keys and a display name
      def normalize(server)
        unless server.is_a?(Hash)
          fail ArgumentError, "Each entry in `mcps:` must be a Hash, got #{server.class}."
        end

        declaration = server.deep_symbolize_keys
        declaration[:name] ||= (declaration[:url].presence || declaration[:command].presence || "unnamed server").to_s

        declaration
      end

      # @param tool [Hash, Object, String, Symbol]
      # @return [String]
      def tool_name(tool)
        return (tool[:name] || tool["name"]).to_s if tool.is_a?(Hash)
        return tool.name.to_s if tool.respond_to?(:name)

        tool.to_s
      end
    end
  end
end
