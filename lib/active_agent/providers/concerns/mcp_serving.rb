# frozen_string_literal: true

require_relative "../mcp_bridge"

module ActiveAgent
  module Providers
    # Serves `mcps:` declarations, natively where a provider's API can and
    # client-side everywhere else.
    #
    # A declaration is passthrough by default: it becomes the provider's own
    # `mcp_servers` parameter, and the provider connects, lists the tools and
    # calls them. That works only where the provider implements MCP, and where it
    # does not the failure is quiet — DeepSeek ignores `mcp_servers`, returns 200,
    # and answers without the server's data, so it reads as a poor answer rather
    # than as a configuration error.
    #
    # The default is therefore inverted here: a provider declares the transports
    # its own API can serve ({#mcp_native_transports}, empty by default) and
    # {MCPBridge} serves the rest, which is what makes `mcps:` work on every
    # provider rather than only the ones that implement it.
    #
    # Each provider may override:
    # - `mcp_native_transports`: the transport kinds its own API can serve
    module MCPServing
      extend ActiveSupport::Concern

      # The accepted `mcp_strategy:` values.
      STRATEGIES = %i[auto client server].freeze

      included do
        # @return [MCPBridge, nil] bridge over the client-side declarations
        attr_internal :mcp_bridge
      end

      # The MCP server transports this provider can serve through its own API.
      #
      # `:url` is a remote server, which a provider that speaks MCP can simply be
      # handed. `:command` is a local process, and no provider can serve one:
      # nothing but this process is going to spawn it, so those always run
      # client-side whatever the provider supports.
      #
      # Empty by default, which is what makes the bridge the universal path —
      # every provider supports `mcps:` whether or not its API does.
      #
      # @return [Array<Symbol>]
      def mcp_native_transports = []

      protected

      # Request parameters for a real prompt, with `mcps:` resolved.
      #
      # Declarations the provider can serve itself are left in `mcps:` for it to
      # translate; the rest are served by {MCPBridge}, which exposes their tools
      # as ordinary tools the provider can already call.
      #
      # @return [Hash]
      def mcp_resolved_context
        native, bridged = mcp_partition_servers(context[:mcps])
        parameters      = mcp_except_options(context)

        parameters = parameters.merge(mcps: native) if native.any?

        # Release a bridge left by an earlier call on this instance before this
        # one replaces the field, or its connections outlive the generation that
        # opened them.
        mcp_release_bridge!
        self.mcp_bridge = bridged.any? ? MCPBridge.new(bridged, cache: context[:mcp_cache]) : nil

        return parameters if mcp_bridge.nil?

        parameters.merge(tools: mcp_bridge.merge_tools(parameters[:tools]))
      end

      # Closes the bridge's server connections, if one was built.
      #
      # A bridged server holds a live connection, and for a `command:` server
      # that connection is a process. It has to be released when the generation
      # that opened it finishes — the garbage collector would never reap it, so
      # a long-lived worker would accumulate orphans until it ran out of PIDs.
      #
      # Safe to call when no bridge was built, and safe to call twice.
      #
      # @return [void]
      def mcp_release_bridge!
        mcp_bridge&.close
        self.mcp_bridge = nil
      end

      # Request parameters for a preview, keeping only what the provider serves.
      #
      # Discovering a server's tools means connecting to it, and a preview must
      # not perform I/O, so a client-side server does not appear in a preview at
      # all — its tools are unknown until it is connected to.
      #
      # @return [Hash]
      def mcp_preview_context
        native, = mcp_partition_servers(context[:mcps])
        parameters = mcp_except_options(context)

        native.any? ? parameters.merge(mcps: native) : parameters
      end

      # @param name [String, Symbol] tool name
      # @return [Boolean] whether a bridged server provides this tool
      def mcp_owns_tool?(name)
        mcp_bridge&.owns?(name) || false
      end

      # Invokes a tool on a bridged server.
      #
      # @param name [String] tool name
      # @param kwargs [Hash] tool arguments
      # @return [Object] the tool's result
      def mcp_call_tool(name, **kwargs) = mcp_bridge.call(name, **kwargs)

      # Splits `mcps:` into what the provider serves and what the bridge serves.
      #
      # @param declarations [Array<Hash>, Hash, nil]
      # @return [Array<Array<Hash>>] the provider's declarations, then the
      #   bridge's
      # @raise [ArgumentError] when `mcp_strategy: :server` was asked for and the
      #   provider cannot serve one of the declarations
      def mcp_partition_servers(declarations)
        declarations = mcp_normalize_declarations(declarations)

        case mcp_strategy
        when :client
          [ [], declarations ]
        when :server
          declarations.each { |declaration| mcp_assert_servable!(declaration) }

          [ declarations, [] ]
        else
          declarations.partition { |declaration| mcp_native_transports.include?(mcp_transport(declaration)) }
        end
      end

      # @return [Symbol] how to serve `mcps:`: `:auto` (default, native where the
      #   provider can and client-side otherwise), `:client` to always run the
      #   servers here, or `:server` to require the provider to run them
      # @raise [ArgumentError] for a value outside `STRATEGIES`
      def mcp_strategy
        strategy = (context[:mcp_strategy] || :auto).to_sym
        return strategy if STRATEGIES.include?(strategy)

        fail ArgumentError, "`mcp_strategy:` must be one of #{STRATEGIES.map(&:inspect).join(', ')}, got #{strategy.inspect}."
      end

      # Removes the MCP options, which are instructions to this concern rather
      # than parameters any provider accepts.
      #
      # @param parameters [Hash]
      # @return [Hash]
      def mcp_except_options(parameters)
        parameters.except(:mcps, :mcp_strategy, :mcp_cache)
      end

      # @param declarations [Array<Hash>, Hash, nil]
      # @return [Array<Hash>]
      def mcp_normalize_declarations(declarations)
        return [] if declarations.blank?
        # `Array(hash)` would split a lone declaration into pairs.
        declarations = [ declarations ] if declarations.is_a?(Hash)

        # A declaration loaded from YAML or JSON arrives with String keys, and `mcp_transport` reads Symbols.
        Array(declarations).map { |declaration| declaration.is_a?(Hash) ? declaration.deep_symbolize_keys : declaration }
      end

      # @param declaration [Hash]
      # @return [Symbol, nil] `:url`, `:command`, or nil when neither is declared
      def mcp_transport(declaration)
        return nil unless declaration.is_a?(Hash)
        return :url if declaration[:url].present?
        return :command if declaration[:command].present?

        nil
      end

      # @param declaration [Hash]
      # @return [void]
      # @raise [ArgumentError] when the provider cannot serve the declaration
      def mcp_assert_servable!(declaration)
        transport = mcp_transport(declaration)

        unless transport && mcp_native_transports.include?(transport)
          fail ArgumentError,
               "#{service_name} cannot serve #{transport ? "a #{transport.inspect}" : "this"} MCP server itself, " \
               "but `mcp_strategy: :server` requires it to. Servers it can serve: " \
               "#{mcp_native_transports.any? ? mcp_native_transports.inspect : "none"}. " \
               "Use `mcp_strategy: :auto` to run the rest client-side."
        end
      end
    end
  end
end
