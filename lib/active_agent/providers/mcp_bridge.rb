# frozen_string_literal: true

require "digest"
require "json"
require "uri"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/object/deep_dup"
require_relative "mcp_tool_cache"

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
      #
      # Frozen, and handed out as a copy, because one constant would otherwise
      # be a single mutable object serving every tool of every server in the
      # process — a transform that wrote to it would corrupt it for everyone.
      EMPTY_SCHEMA = { type: "object", properties: {}.freeze }.freeze

      # Seconds to wait for a server to answer before abandoning the connection.
      #
      # A stdio read blocks forever without one, so a server that accepts a
      # request and never replies holds the generation open until the worker is
      # restarted. Generous, since a tool call can legitimately be slow; set
      # `read_timeout:` on a declaration to override it.
      DEFAULT_READ_TIMEOUT = 30

      # A declared server, paired with the client connected to it.
      Server = Struct.new(:name, :declaration, :client, keyword_init: true)

      # @param servers [Array<Hash>, Hash, nil] common-format `mcps:`
      #   declarations. A single Hash is accepted as a one-server list, because
      #   `Array(some_hash)` would split it into pairs.
      def initialize(servers, cache: nil)
        @declarations = normalize_all(servers)
        @tools        = nil
        @ownership    = {}
        # Every connection attempted, so a failed handshake is still reaped.
        @servers      = []
        # Only the connections that succeeded, so a failure is not reused.
        @connections  = {}
        @cache        = cache
      end

      # @return [Boolean] whether no servers were declared
      def empty? = @declarations.empty?

      # Closes every connection this bridge opened.
      #
      # A stdio server is a process this process spawned, and it is reaped only
      # by its transport's `close` — so a bridge that is simply dropped leaks a
      # child process per generation, which accumulates in a long-lived worker.
      # The wrapper exposes no `close` of its own; the transport is where it
      # lives.
      #
      # Idempotent, and deliberately never raises: it runs while a generation is
      # finishing, often from an `ensure`, and a teardown failure must not
      # replace the error that generation was already carrying. Closing resets
      # the discovered tools, so a bridge that is closed and used again
      # reconnects rather than handing back stale clients.
      #
      # @return [void]
      def close
        servers      = @servers || []
        @servers     = []
        @connections = {}
        @tools       = nil
        @ownership   = {}

        servers.each do |server|
          transport = server.client.transport if server.client.respond_to?(:transport)
          next unless transport.respond_to?(:close)

          begin
            transport.close
          rescue StandardError
            # Best effort — see above. A server that will not shut down cleanly
            # is not worth failing a finished generation over.
          end
        end

        nil
      end

      # Every tool the declared servers offer, in the common format.
      #
      # Served from {MCPToolCache} when it has an entry, in which case no
      # connection is opened at all.
      #
      # @return [Array<Hash>]
      def tools
        discover if @tools.nil?
        @tools
      end

      # Drops the cached tool lists and closes anything open, so the next use
      # asks the servers again. For a caller that has learned — from a tool the
      # server no longer provides, say — that its view is stale.
      #
      # @return [void]
      def refresh!
        @declarations.each { |declaration| MCPToolCache.invalidate(fingerprint_for(declaration)) }
        close
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

        declaration = @ownership.fetch(name.to_s) do
          fail ArgumentError, "No declared MCP server provides a tool named #{name.to_s.inspect}."
        end

        server = ensure_connected(declaration)

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

      # Works out which tools each declared server offers.
      #
      # Connections are deliberately left alone: a cache hit means this needs
      # none, and one that is opened here only to be closed again would defeat
      # the point.
      #
      # @return [void]
      def discover
        @tools     = []
        @ownership = {}

        @declarations.each do |declaration|
          tools_for(declaration).each do |tool|
            existing = @ownership[tool[:name]]

            if existing
              fail DuplicateToolError,
                   "Two declared MCP servers offer a tool named #{tool[:name].inspect}: " \
                   "#{existing[:name].to_s.inspect} and #{declaration[:name].to_s.inspect}. The model cannot choose " \
                   "between them, so rename one or restrict it with `allowed_tools:`."
            end

            @ownership[tool[:name]] = declaration
            @tools << tool
          end
        end
      end

      # The tools one declaration offers, from the cache where it can be.
      #
      # @param declaration [Hash]
      # @return [Array<Hash>]
      def tools_for(declaration)
        MCPToolCache.fetch(fingerprint_for(declaration), enabled: @cache) do
          server_tools(ensure_connected(declaration))
        end
      end

      # The live connection to a declaration's server, opening it on first use.
      #
      # This is what the cache buys: a generation whose tools all come from the
      # cache and never calls one opens no connection and spawns no process.
      #
      # @param declaration [Hash]
      # @return [Server]
      def ensure_connected(declaration)
        @connections[declaration] ||= connect(declaration)
      end

      # Identifies a declaration for caching purposes.
      #
      # Covers what can change the advertised tools: endpoint, credentials,
      # command environment and tool filter. Credentials are hashed along with
      # the rest of the declaration; the raw secret is never used as a cache
      # key. The display name is excluded, so renaming a server does not throw
      # away its cached tools.
      #
      # @param declaration [Hash]
      # @return [String]
      def fingerprint_for(declaration)
        canonical = {
          url:           declaration[:url],
          command:       declaration[:command],
          args:          declaration[:args],
          env:           declaration[:env]&.sort&.to_h,
          authorization: declaration[:authorization],
          authorization_token: declaration[:authorization_token],
          allowed_tools: declaration[:allowed_tools]&.map { |tool| tool_name(tool) }&.sort
        }

        Digest::SHA256.hexdigest(JSON.generate(canonical))
      end

      # Connects a client to one declared server.
      #
      # The server is recorded before it is connected, because `connect` starts a
      # stdio process and only then handshakes: a handshake that fails — a
      # mistyped command, a server that never answers — has already spawned a
      # process, and recording it afterwards would leave that process with
      # nothing to reap it. It is only remembered for reuse once it succeeds.
      #
      # @param declaration [Hash]
      # @return [Server]
      def connect(declaration)
        self.class.load_mcp!

        client = MCP::Client.new(transport: transport_for(declaration))
        server = Server.new(name: declaration[:name], declaration:, client:)
        @servers << server

        client.connect
        server
      end

      # @param declaration [Hash]
      # @return [Object] an MCP transport
      def transport_for(declaration)
        if declaration[:url]
          MCP::Client::HTTP.new(
            url:     declaration[:url],
            headers: headers_for(declaration),
            **{ max_reconnection_wait: declaration[:max_reconnection_wait] }.compact
          )
        elsif declaration[:command]
          MCP::Client::Stdio.new(
            command:      declaration[:command],
            args:         Array(declaration[:args]),
            env:          declaration[:env],
            read_timeout: read_timeout_for(declaration)
          )
        else
          fail ArgumentError,
               "An entry in `mcps:` needs either a `url:` or a `command:` to connect to, " \
               "got #{declaration.inspect}."
        end
      end

      # The bounded wait for a server to answer.
      #
      # @param declaration [Hash]
      # @return [Numeric]
      # @raise [ArgumentError] when a declared timeout is not a positive number
      def read_timeout_for(declaration)
        timeout = declaration[:read_timeout]
        return DEFAULT_READ_TIMEOUT if timeout.nil?

        unless timeout.is_a?(Numeric) && timeout.positive?
          fail ArgumentError,
               "`read_timeout:` on an MCP server must be a positive number of seconds, got #{timeout.inspect}."
        end

        timeout
      end

      # @return [Hash] a fresh copy of {EMPTY_SCHEMA}, safe for a caller to mutate
      def empty_schema = EMPTY_SCHEMA.deep_dup

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
            parameters:  tool.input_schema || empty_schema
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
        declaration[:name] ||= default_name(declaration)

        declaration
      end

      # A display name for a declaration that gave none.
      #
      # Deliberately the host rather than the whole URL. An MCP endpoint usually
      # carries its key in the path (`https://mcp.example.com/<key>/v2/mcp`),
      # and this name reaches error messages, which reach log aggregators and
      # error trackers — so the URL is the one part of the declaration that must
      # not be copied into them.
      #
      # @param declaration [Hash]
      # @return [String]
      def default_name(declaration)
        return "command: #{File.basename(declaration[:command].to_s)}" if declaration[:command].present?

        url = declaration[:url]
        return "unnamed server" if url.blank?

        URI.parse(url).host || "unnamed server"
      rescue URI::InvalidURIError
        "unnamed server"
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
