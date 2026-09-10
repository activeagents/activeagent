# frozen_string_literal: true

module ActionAgent
  # Browser callers retain their default endpoint and process singleton;
  # discovery and transport are shared with configured MCP services.
  class PlaywrightMCPClient < MCPClient
    DEFAULT_URL = ENV.fetch("PLAYWRIGHT_MCP_URL", "http://host.orb.internal:8931/mcp")

    def self.instance
      @instance ||= new
    end

    def self.reset!
      @instance = nil
    end

    def initialize(url: DEFAULT_URL, transport: "http")
      super
    end

    private

    def reset_session!
      super
      self.class.reset!
    end
  end
end
