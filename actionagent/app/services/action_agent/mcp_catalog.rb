# frozen_string_literal: true

module ActionAgent
  # The catalog of MCP servers the dashboard knows about.
  #
  # Serves three jobs that would otherwise each need their own list:
  #
  # 1. **Listing** — the MCP Services view shows these as the servers a
  #    workspace can connect, whether or not it has used one yet.
  # 2. **Attribution** — telemetry only carries the tool name a provider
  #    invoked. When that name is namespaced (+mcp__playwright__…+) the server
  #    is explicit; when it isn't, TOOL_HINTS maps well-known bare tool names
  #    back to the server that serves them, so a workspace running the
  #    reference servers still gets grouped traffic instead of a flat list.
  # 3. **Provisioning** — entries marked +sandbox: true+ can be started inside
  #    a sandbox session, using the command recorded here.
  #
  # Detection never depends on this catalog: a server that isn't listed still
  # shows up in the MCP Services view (as +known: false+) the moment a
  # namespaced tool call from it is ingested. The catalog only adds names,
  # descriptions, and the ability to launch.
  class MCPCatalog
    # Whether a server can be started inside a sandbox session. Servers that
    # need workspace-specific credentials (github, slack, postgres) are
    # listable and attributable but not launchable from the dashboard — there
    # is nowhere safe to source their secrets from yet.
    SERVERS = [
      {
        key: "playwright",
        name: "Playwright",
        description: "Drives a real browser: navigate pages, snapshot the accessibility tree, click elements.",
        transport: "stdio",
        command: "npx @playwright/mcp@latest",
        package: "@playwright/mcp",
        categories: %w[browser automation],
        docs_url: "https://github.com/microsoft/playwright-mcp",
        sandbox: true,
        sandbox_type: "playwright_mcp",
        # The platform's own Playwright tools (AgentToolbox "playwright_mcp")
        # invoke these bare, without the mcp__ namespace.
        tool_hints: %w[browser_navigate browser_snapshot browser_click browser_type browser_take_screenshot]
      },
      {
        key: "filesystem",
        name: "Filesystem",
        description: "Reads and writes files under an allow-listed set of directories.",
        transport: "stdio",
        command: "npx @modelcontextprotocol/server-filesystem",
        package: "@modelcontextprotocol/server-filesystem",
        categories: %w[files],
        docs_url: "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem",
        sandbox: true,
        sandbox_type: "terminal",
        tool_hints: %w[read_file read_text_file write_file edit_file list_directory directory_tree move_file search_files]
      },
      {
        key: "fetch",
        name: "Fetch",
        description: "Fetches a URL and converts the page to markdown for the model to read.",
        transport: "stdio",
        command: "uvx mcp-server-fetch",
        package: "mcp-server-fetch",
        categories: %w[web],
        docs_url: "https://github.com/modelcontextprotocol/servers/tree/main/src/fetch",
        sandbox: true,
        sandbox_type: "research",
        tool_hints: %w[fetch fetch_url]
      },
      {
        key: "git",
        name: "Git",
        description: "Reads and manipulates a local git repository: status, diff, log, commit.",
        transport: "stdio",
        command: "uvx mcp-server-git",
        package: "mcp-server-git",
        categories: %w[code vcs],
        docs_url: "https://github.com/modelcontextprotocol/servers/tree/main/src/git",
        sandbox: true,
        sandbox_type: "terminal",
        tool_hints: %w[git_status git_diff git_log git_commit git_add git_create_branch]
      },
      {
        key: "memory",
        name: "Memory",
        description: "A persistent knowledge graph the agent can write facts to and recall across runs.",
        transport: "stdio",
        command: "npx @modelcontextprotocol/server-memory",
        package: "@modelcontextprotocol/server-memory",
        categories: %w[memory],
        docs_url: "https://github.com/modelcontextprotocol/servers/tree/main/src/memory",
        sandbox: true,
        sandbox_type: "terminal",
        tool_hints: %w[create_entities create_relations add_observations search_nodes read_graph]
      },
      {
        key: "sequential-thinking",
        name: "Sequential Thinking",
        description: "Gives the model a scratchpad for multi-step reasoning it can revise as it goes.",
        transport: "stdio",
        command: "npx @modelcontextprotocol/server-sequential-thinking",
        package: "@modelcontextprotocol/server-sequential-thinking",
        categories: %w[reasoning],
        docs_url: "https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking",
        sandbox: true,
        sandbox_type: "research",
        tool_hints: %w[sequentialthinking]
      },
      {
        key: "github",
        name: "GitHub",
        description: "Reads and writes GitHub issues, pull requests, and repository contents.",
        transport: "http",
        url: "https://api.githubcopilot.com/mcp/",
        categories: %w[code vcs],
        docs_url: "https://github.com/github/github-mcp-server",
        sandbox: false,
        requires_credentials: [ "GITHUB_TOKEN" ],
        tool_hints: %w[create_issue get_issue list_issues create_pull_request get_file_contents search_code]
      },
      {
        key: "slack",
        name: "Slack",
        description: "Posts messages and reads channel history in a connected Slack workspace.",
        transport: "stdio",
        command: "npx @modelcontextprotocol/server-slack",
        package: "@modelcontextprotocol/server-slack",
        categories: %w[communication],
        docs_url: "https://github.com/modelcontextprotocol/servers/tree/main/src/slack",
        sandbox: false,
        requires_credentials: [ "SLACK_BOT_TOKEN", "SLACK_TEAM_ID" ],
        tool_hints: %w[slack_post_message slack_list_channels slack_get_channel_history]
      },
      {
        key: "postgres",
        name: "Postgres",
        description: "Runs read-only SQL against a Postgres database and inspects its schema.",
        transport: "stdio",
        command: "npx @modelcontextprotocol/server-postgres",
        package: "@modelcontextprotocol/server-postgres",
        categories: %w[data],
        docs_url: "https://github.com/modelcontextprotocol/servers/tree/main/src/postgres",
        sandbox: false,
        requires_credentials: [ "DATABASE_URL" ],
        tool_hints: %w[query describe_table list_tables]
      },
      {
        key: "activeagents",
        name: "Active Agent",
        description: "This dashboard's own agents, exposed as MCP tools and agent:// resources over Streamable HTTP.",
        transport: "http",
        # Relative to wherever the engine is mounted — the same <mount>/mcp
        # route the dashboard serves.
        url: "<mount>/mcp",
        categories: %w[agents platform],
        docs_url: "https://docs.activeagents.ai/mcp",
        sandbox: false,
        first_party: true,
        requires_credentials: [ "Platform API key" ],
        tool_hints: %w[call_agent list_agents]
      }
    ].freeze

    # key => entry, for O(1) lookup by name.
    BY_KEY = SERVERS.index_by { |server| server[:key] }.freeze

    # Bare tool name => server key. Built from each entry's tool_hints, so
    # adding a server to SERVERS is all it takes to teach attribution about
    # its tools. First declaration wins on collision (a name served by two
    # catalog entries stays with the earlier, more specific one).
    TOOL_HINTS = SERVERS.each_with_object({}) do |server, map|
      Array(server[:tool_hints]).each { |tool| map[tool] ||= server[:key] }
    end.freeze

    class << self
      # Every catalog entry, as API-shaped hashes.
      #
      # @return [Array<Hash>]
      def all
        SERVERS.map { |server| present(server) }
      end

      # Entries that can be started inside a sandbox session.
      #
      # @return [Array<Hash>]
      def launchable
        all.select { |server| server[:sandbox] }
      end

      # @param key [String, Symbol]
      # @return [Hash, nil] the catalog entry, or nil when unknown
      def find(key)
        entry = BY_KEY[key.to_s]
        present(entry) if entry
      end

      # @param key [String, Symbol]
      # @return [Boolean] whether the server can be started in a sandbox
      def launchable?(key)
        BY_KEY[key.to_s]&.fetch(:sandbox, false) || false
      end

      # The catalog server a bare (non-namespaced) tool name belongs to.
      #
      # Only consulted after namespace parsing fails — an explicit
      # +mcp__server__tool+ name always wins over a hint, because the trace
      # said so and this table is only an educated guess.
      #
      # @param tool_name [String, Symbol]
      # @return [String, nil] the server key
      def server_for_tool(tool_name)
        TOOL_HINTS[tool_name.to_s]
      end

      # The display name for a server key, falling back to the key itself for
      # servers detected in telemetry but absent from the catalog.
      #
      # @param key [String, Symbol]
      # @return [String]
      def display_name(key)
        BY_KEY[key.to_s]&.fetch(:name) || key.to_s
      end

      private

      # Drops the internal-only tool_hints and normalizes optional keys so
      # every entry serializes with the same shape.
      def present(server)
        {
          key: server[:key],
          name: server[:name],
          description: server[:description],
          transport: server[:transport],
          command: server[:command],
          url: server[:url],
          package: server[:package],
          categories: Array(server[:categories]),
          docs_url: server[:docs_url],
          sandbox: server.fetch(:sandbox, false),
          sandbox_type: server[:sandbox_type],
          first_party: server.fetch(:first_party, false),
          requires_credentials: Array(server[:requires_credentials]),
          tools: Array(server[:tool_hints])
        }
      end
    end
  end
end
