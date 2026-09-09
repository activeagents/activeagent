# frozen_string_literal: true

module ActionAgent
  # The coding agents a code session can hand an agent to, and what each one
  # needs and cannot do inside a sandbox.
  #
  # The dashboard runs these through a backend, and today's backend is
  # code-on-incus (the `coi` CLI), which knows a fixed set of tools by name:
  # +coi_tool+ is the value it accepts for +[tool] name+, and nil means the
  # tool is not one of coi's, so it is invoked as a plain command inside the
  # container instead and only works if the image carries it.
  #
  # +headless+ is the distinction that decides how a run is issued, and it is
  # deliberately narrow: coi documents `coi run --prompt-file` for the claude
  # tool with `permission_mode = "bypass"`, and nothing else. Every other
  # entry is driven through `coi run -- <argv>` from +headless_command+, is
  # marked +experimental+, and says so in the UI rather than pretending.
  #
  # +credentials+ is an array of any-of groups: each inner array is satisfied
  # when any one of its environment variables can be supplied. Only the NAMES
  # ever leave this class; values are resolved per run and handed to the
  # backend, never persisted (see ActionAgent.github_token_for and
  # ActionAgent.provider_credentials).
  class CodeAgentCatalog
    Entry = Struct.new(
      :key, :name, :vendor, :coi_tool, :headless, :headless_command, :credentials,
      :provider, :needs, :limitations, :docs_url, :experimental,
      keyword_init: true
    ) do
      def headless? = headless == true
      def experimental? = experimental == true

      # Every environment variable this tool could authenticate with, flat.
      def credential_names = credentials.flatten.map(&:to_s)

      # The argv that runs +prompt_path+ non-interactively inside the
      # container, or nil for a tool that only supports an interactive
      # session (the user attaches to it).
      def command_for(prompt_path)
        return nil if headless_command.nil?

        headless_command.map { |part| part.gsub("%{prompt_file}", prompt_path.to_s) }
      end

      def as_json_summary
        {
          key: key,
          name: name,
          vendor: vendor,
          headless: headless?,
          experimental: experimental?,
          credentials: credentials,
          needs: needs,
          limitations: limitations,
          docs_url: docs_url
        }
      end
    end

    # Ordered: the default first, then the other vendor CLIs, then the
    # open-source agents.
    ENTRIES = [
      Entry.new(
        key: "claude_code",
        name: "Claude Code",
        vendor: "Anthropic",
        coi_tool: "claude",
        headless: true,
        headless_command: nil,
        credentials: [ %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN] ],
        provider: "anthropic",
        needs: [
          "An Anthropic API key, or a Claude subscription token, seeded into the container",
          "A task it can finish without asking: prompts are answered by nobody inside a sandbox"
        ],
        limitations: [
          "Runs with permission prompts bypassed inside the sandbox, so read its diff before merging",
          "Reaches only the hosts the session's network mode allows"
        ],
        docs_url: "https://docs.claude.com/en/docs/claude-code",
        experimental: false
      ),
      Entry.new(
        key: "codex",
        name: "Codex CLI",
        vendor: "OpenAI",
        coi_tool: "codex",
        headless: false,
        headless_command: [ "codex", "exec", "--full-auto", "@%{prompt_file}" ],
        credentials: [ %w[OPENAI_API_KEY] ],
        provider: "openai",
        needs: [ "An OpenAI API key seeded into the container" ],
        limitations: [
          "Driven through a plain command rather than code-on-incus's own headless path, so its exit code is the only completion signal",
          "Reaches only the hosts the session's network mode allows"
        ],
        docs_url: "https://developers.openai.com/codex/cli",
        experimental: true
      ),
      Entry.new(
        key: "copilot",
        name: "GitHub Copilot CLI",
        vendor: "GitHub",
        coi_tool: nil,
        headless: false,
        headless_command: [ "copilot", "-p", "@%{prompt_file}", "--allow-all-tools" ],
        credentials: [ %w[GH_TOKEN GITHUB_TOKEN] ],
        provider: nil,
        needs: [
          "A GitHub token whose account has an active Copilot subscription",
          "An image with the Copilot CLI installed: it is not one of code-on-incus's own tools"
        ],
        limitations: [
          "Not a code-on-incus tool, so its credentials are seeded by this engine rather than by coi",
          "Authenticates with the same token the session clones with, so read-only GitHub access limits it too"
        ],
        docs_url: "https://docs.github.com/copilot/concepts/agents/about-copilot-cli",
        experimental: true
      ),
      Entry.new(
        key: "opencode",
        name: "opencode",
        vendor: "Open source",
        coi_tool: "opencode",
        headless: false,
        headless_command: [ "opencode", "run", "@%{prompt_file}" ],
        credentials: [ %w[ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY] ],
        provider: nil,
        needs: [ "A key for whichever provider its configured model runs on" ],
        limitations: [ "Model choice lives in its own configuration, so the session's model override may not apply" ],
        docs_url: "https://opencode.ai",
        experimental: true
      ),
      Entry.new(
        key: "pi",
        name: "pi",
        vendor: "Open source",
        coi_tool: "pi",
        headless: false,
        headless_command: nil,
        credentials: [ %w[ANTHROPIC_API_KEY OPENAI_API_KEY] ],
        provider: nil,
        needs: [ "A provider key, and someone to attach to the session: it has no headless mode here" ],
        limitations: [ "Interactive only: start the session, then attach to drive it" ],
        docs_url: nil,
        experimental: true
      ),
      Entry.new(
        key: "omp",
        name: "Oh My Pi",
        vendor: "Open source",
        coi_tool: "omp",
        headless: false,
        headless_command: nil,
        credentials: [ %w[ANTHROPIC_API_KEY OPENAI_API_KEY] ],
        provider: nil,
        needs: [ "A provider key, and someone to attach to the session: it has no headless mode here" ],
        limitations: [ "Interactive only: start the session, then attach to drive it" ],
        docs_url: nil,
        experimental: true
      ),
      Entry.new(
        key: "aider",
        name: "aider",
        vendor: "Open source",
        coi_tool: nil,
        headless: false,
        headless_command: [ "aider", "--yes", "--message-file", "%{prompt_file}" ],
        credentials: [ %w[ANTHROPIC_API_KEY OPENAI_API_KEY] ],
        provider: nil,
        needs: [ "An image with aider installed: it is not one of code-on-incus's own tools" ],
        limitations: [ "Edits files and commits, but does not open pull requests itself" ],
        docs_url: "https://aider.chat",
        experimental: true
      )
    ].freeze

    BY_KEY = ENTRIES.index_by(&:key).freeze

    class << self
      def all = ENTRIES

      def keys = BY_KEY.keys

      # @return [Entry, nil]
      def find(key)
        BY_KEY[key.to_s]
      end

      def display_name(key)
        find(key)&.name || key.to_s
      end

      # The entries +backend+ can actually launch, asked of the backend
      # itself so a host-registered one answers for its own image.
      def supported_by(backend)
        supported = backend.respond_to?(:supported_tools) ? Array(backend.supported_tools).map(&:to_s) : keys
        ENTRIES.select { |entry| supported.include?(entry.key) }
      end
    end
  end
end
