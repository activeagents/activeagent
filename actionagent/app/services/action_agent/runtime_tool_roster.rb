# frozen_string_literal: true

module ActionAgent
  # Used to list the tools an agent can call in a run: the engine's toolbox
  # tools its saved +tools+ name, and whatever its MCP servers and the run's
  # extra checkout sandboxes and browsers serve (MCPToolDispatcher). When a
  # sandbox's browser is attached, the toolbox's own browser tools drop. A scenario run's
  # diagnosis and an exploration's answerability verdicts read the same list.
  #
  # AgentToolRoster is a different list: the agent editor's view of every
  # tool and service the agent could be given, with usage.
  class RuntimeToolRoster
    attr_reader :agent, :dispatcher

    # @param agent [Agent]
    # @param extra_server_keys [Array<String>] "sandbox:<session_id>" and
    #   "browser:<session_id>" keys the run reaches beside the agent's own
    #   servers
    def initialize(agent, extra_server_keys: [])
      @agent = agent
      @dispatcher = MCPToolDispatcher.new(agent, extra_server_keys: extra_server_keys)
    end

    # Returns { name => description } for every tool the agent can call. A
    # server that fails discovery contributes nothing and is named in
    # #discovery_errors.
    #
    # @raise [MCPToolDispatcher::SandboxUnavailable] when an extra sandbox is
    #   not live or does not answer discovery
    # @return [Hash{String => String}]
    def tools
      @tools ||= (dispatcher.tool_definitions +
        AgentToolbox.definitions_for(agent.tools, browser_attached: dispatcher.browser_attached?))
        .to_h { |definition| [ definition[:name].to_s, definition[:description].to_s ] }
    end

    # Why each of the agent's own servers contributed no tools, keyed by
    # server; empty when every one answered.
    #
    # @return [Hash{String => String}]
    def discovery_errors
      tools
      dispatcher.discovery_errors
    end

    # Whether every server the agent declares failed discovery.
    def all_servers_failed?
      tools
      dispatcher.all_servers_failed?
    end
  end
end
