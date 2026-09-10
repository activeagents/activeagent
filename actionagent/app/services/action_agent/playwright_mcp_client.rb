# frozen_string_literal: true

module ActionAgent
  # The Playwright MCP server as one configured MCPClient: a process-wide
  # instance pointed at the url PLAYWRIGHT_MCP_URL names.
  class PlaywrightMCPClient < MCPClient
    DEFAULT_URL = ENV.fetch("PLAYWRIGHT_MCP_URL", "http://host.orb.internal:8931/mcp")

    def self.instance
      @instance ||= new
    end

    def self.reset!
      @instance = nil
    end

    def initialize(url: DEFAULT_URL)
      super(url: url, label: "Playwright")
    end

    # Restarting the shared instance on an unreachable server is this
    # subclass's concern: the next call re-initializes rather than reusing a
    # session the server has forgotten. The message names the local fix.
    def call_tool(name, arguments = {})
      super
    rescue MCPClient::Error => e
      self.class.reset!
      raise Error, "#{e.message}: start it with `npx @playwright/mcp --port 8931`" if e.message.include?("unreachable")

      raise
    end
  end
end
