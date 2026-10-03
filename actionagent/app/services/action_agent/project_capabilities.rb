# frozen_string_literal: true

module ActionAgent
  # Used to tell the New Project page what this install can do for a
  # project, as a checklist. Each item says whether it holds and, when it
  # does not, the configuration line or step that fixes it. A blocking item
  # that fails keeps a project from being created (Api::ProjectsController).
  #
  #   sandbox_backend    a backend that runs checkouts. The mock backend runs
  #                      nothing, so it is refused outside the test
  #                      environment
  #   local_sandboxes    :local only: whether it is enabled
  #   boot_spec          the backend takes a boot spec, which is how a
  #                      project's secrets and bootstrap reach it
  #   execution          agent execution is enabled
  #   github             a GitHub App or OAuth app is configured
  #   github_connection  the owner connected GitHub
  #   model_credentials  credentials for the model the project's agent
  #                      runs on (not blocking)
  #   browser            browser sessions (not blocking; not available yet)
  #   code_runners       Claude Code or Codex sessions (not blocking)
  class ProjectCapabilities
    Item = Struct.new(:key, :label, :ok, :blocking, :detail, :fix, keyword_init: true)

    # @param owner [Object, nil] the caller's owner, for its credentials
    # @param github_connected [Boolean]
    # @param base_url [String] the engine's absolute mount URL, for callback URLs
    # @param environment [ActiveSupport::EnvironmentInquirer]
    def initialize(owner:, github_connected:, base_url:, environment: Rails.env)
      @owner = owner
      @github_connected = github_connected
      @base_url = base_url
      @environment = environment
    end

    # @return [Hash] { ready:, items: [Item#to_h], backend:, github:,
    #   default_model:, browser:, code_runners:, local_boot: }
    def call
      return @result if @result

      items = [ backend_item, *local_item, boot_spec_item, execution_item, github_item, github_connection_item,
                model_item, browser_item, code_runners_item ]
      @result = {
        ready: items.none? { |item| item.blocking && !item.ok },
        items: items.map(&:to_h),
        backend: backend_name,
        github: github,
        default_model: default_model,
        browser: { available: false },
        code_runners: code_runners,
        local_boot: orchestrator&.local? || false
      }
    end

    # The blocking items that fail, as #call lists them.
    def blocking_failures
      call[:items].select { |item| item[:blocking] && !item[:ok] }
    end

    private

    def orchestrator
      return @orchestrator if defined?(@orchestrator)

      @orchestrator = begin
        SandboxOrchestrator.new
      rescue StandardError, LoadError => e
        @backend_error = e.message
        nil
      end
    end

    def backend_name
      SandboxOrchestrator.default_backend
    end

    def backend_item
      name = backend_name
      if orchestrator.nil?
        return Item.new(key: "sandbox_backend", label: "Sandbox backend", ok: false, blocking: true,
          detail: "The #{name} backend could not be loaded: #{@backend_error}",
          fix: "Check ActionAgent.sandbox_backends in config/initializers/action_agent.rb")
      end

      mock_refused = name == "mock" && !@environment.test?
      Item.new(
        key: "sandbox_backend", label: "Sandbox backend", ok: !mock_refused, blocking: true,
        detail: mock_refused ? "The mock backend runs nothing, so a project could never boot" : name,
        fix: mock_refused ? "config.sandbox_service = :local  # config/initializers/action_agent.rb, or a backend you registered" : nil
      )
    end

    def local_item
      return [] unless orchestrator&.local?

      enabled = ActionAgent.local_sandboxes_enabled?
      [ Item.new(key: "local_sandboxes", label: "Local sandboxes", ok: enabled, blocking: true,
        detail: enabled ? "Checkouts run as processes of this dashboard" : "Local sandboxes are off in this environment",
        fix: enabled ? nil : "config.local_sandboxes_enabled = true  # config/initializers/action_agent.rb") ]
    end

    def boot_spec_item
      ok = orchestrator&.accepts_boot_config? || false
      Item.new(key: "boot_spec", label: "Boot spec support", ok: ok, blocking: true,
        detail: ok ? "The backend boots a checkout from the project's spec" : "The #{backend_name} backend takes no boot spec",
        fix: ok ? nil : "Use a sandbox backend whose create_sandbox accepts boot_config:")
    end

    def execution_item
      ok = ActionAgent.execution_enabled?
      Item.new(key: "execution", label: "Agent execution", ok: ok, blocking: true,
        detail: ok ? "Enabled" : "Agent execution is disabled on this dashboard",
        fix: ok ? nil : "config.execution_enabled = true  # config/initializers/action_agent.rb")
    end

    def github
      app = ActionAgent.respond_to?(:github_app_configured?) && ActionAgent.github_app_configured?
      oauth = ActionAgent.github_oauth_configured?
      mode = if app then "app" elsif oauth then "oauth" else "none" end
      {
        mode: mode,
        callback_url: mode == "app" ? "#{@base_url}/api/github_installations/callback" : "#{@base_url}/api/github_connection/callback",
        connected: @github_connected,
        # Where an OAuth app's access to an organization's repositories is
        # granted or requested.
        access_settings_url: oauth ? "https://github.com/settings/connections/applications/#{ActionAgent.github_client_id}" : nil
      }
    end

    def github_item
      info = github
      ok = info[:mode] != "none"
      Item.new(key: "github", label: "GitHub", ok: ok, blocking: true,
        detail: ok ? "#{info[:mode] == "app" ? "GitHub App" : "OAuth app"}, callback URL #{info[:callback_url]}" : "No GitHub app is configured",
        fix: ok ? nil : "Create a GitHub OAuth app with the callback URL #{info[:callback_url]}, then set GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET")
    end

    def github_connection_item
      Item.new(key: "github_connection", label: "GitHub connection", ok: @github_connected, blocking: true,
        detail: @github_connected ? "Connected" : "GitHub is not connected",
        fix: @github_connected ? nil : "Connect GitHub in Settings → Integrations")
    end

    def default_model
      @default_model ||= begin
        provider, model = Project.assistant_model(@owner)
        configured = begin
          DashboardAssistantService.new(owner: @owner).configuration[:providers].any? { |entry| entry[:id] == provider && entry[:configured] }
        rescue StandardError
          false
        end
        { provider: provider, model: model, configured: configured }
      end
    end

    def model_item
      model = default_model
      Item.new(key: "model_credentials", label: "Model credentials", ok: model[:configured], blocking: false,
        detail: model[:configured] ? "#{model[:provider]} #{model[:model]}" : "No provider has credentials for the project's agent",
        fix: model[:configured] ? nil : "Add an Anthropic, OpenAI or OpenRouter key in Settings → Provider API Keys")
    end

    def browser_item
      Item.new(key: "browser", label: "Browser sessions", ok: false, blocking: false,
        detail: "Not available yet: a project's agent works through the app's tools", fix: nil)
    end

    def code_runners
      return [] if orchestrator.nil?

      %w[claude_code codex].select { |runner| orchestrator.supports_code_runner?(runner) }
    rescue StandardError
      []
    end

    def code_runners_item
      runners = code_runners
      Item.new(key: "code_runners", label: "Code sessions", ok: runners.any?, blocking: false,
        detail: runners.any? ? runners.join(", ") : "The backend runs no Claude Code or Codex sessions", fix: nil)
    end
  end
end
