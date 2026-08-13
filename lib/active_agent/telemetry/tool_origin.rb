# frozen_string_literal: true

module ActiveAgent
  module Telemetry
    # Classifies where a tool call came from, so dashboards can group tool
    # traffic by the service that serves it instead of showing a flat list
    # of names.
    #
    # Telemetry only ever sees the name a provider used to invoke the tool,
    # so the origin has to be recovered from naming conventions. The MCP
    # ecosystem settled on a namespaced form — +mcp__<server>__<tool>+ —
    # which most clients (Claude Code, Cursor, the Ruby MCP clients) emit
    # verbatim, and that is the strongest signal available. Everything else
    # falls back to "the agent class defines this method".
    #
    # Classification happens at instrumentation time rather than at read
    # time so the attribution is recorded in the span itself: a trace stays
    # self-describing, and consumers (the gem dashboard, activeagents.ai,
    # any OTLP exporter) all read the same fields instead of each
    # re-implementing the guess.
    #
    # @example Namespaced MCP tool
    #   ToolOrigin.classify("mcp__playwright__browser_navigate")
    #   # => { origin: "mcp", server: "playwright", tool: "browser_navigate" }
    #
    # @example Agent-defined method
    #   ToolOrigin.classify("lookup_order")
    #   # => { origin: "agent", server: nil, tool: "lookup_order" }
    module ToolOrigin
      # +mcp__<server>__<tool>+. The tool half may itself contain "__", so
      # only the first two segments are structural.
      MCP_PATTERN = /\Amcp__([^_]+(?:_[^_]+)*?)__(.+)\z/

      # Origin values written to +tool.origin+.
      MCP = "mcp"
      AGENT = "agent"

      module_function

      # Classifies a tool name.
      #
      # @param name [String, Symbol] the tool name as the provider invoked it
      # @return [Hash] +:origin+ ("mcp" or "agent"), +:server+ (MCP server
      #   name or nil), and +:tool+ (the bare tool name with any namespace
      #   stripped)
      def classify(name)
        name = name.to_s

        if (match = MCP_PATTERN.match(name))
          { origin: MCP, server: match[1], tool: match[2] }
        else
          { origin: AGENT, server: nil, tool: name }
        end
      end

      # Whether a tool name is namespaced to an MCP server.
      #
      # @param name [String, Symbol]
      # @return [Boolean]
      def mcp?(name)
        MCP_PATTERN.match?(name.to_s)
      end

      # The MCP server a tool belongs to, if any.
      #
      # @param name [String, Symbol]
      # @return [String, nil]
      def server_for(name)
        classify(name)[:server]
      end

      # Writes the classification onto a span. Only sets +tool.mcp_server+
      # when there is a server to name, so agent-defined tools don't carry
      # an empty attribute.
      #
      # @param span [ActiveAgent::Telemetry::Span]
      # @param name [String, Symbol] the tool name
      # @return [Hash] the classification, for callers that also want it
      def annotate(span, name)
        classification = classify(name)
        span.set_attribute("tool.origin", classification[:origin])
        if classification[:server]
          span.set_attribute("tool.mcp_server", classification[:server])
          span.set_attribute("tool.base_name", classification[:tool])
        end
        classification
      end
    end
  end
end
