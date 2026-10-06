# frozen_string_literal: true

module ActionAgent
  # Used to publish what a project's bootstrap wrote into its checkout as a
  # pull request that installs the engine in the repository: the install
  # pull request. Publishing goes through DraftPullRequestPublisher, from the
  # project's live sandbox, and takes only the paths of #allowlist:
  #
  #   Gemfile, Gemfile.lock
  #   config/initializers/action_agent.rb, config/routes.rb
  #   config/active_agent.yml and app/agents/application_agent.rb, when the
  #     bootstrap generated them (the repository locked no activeagent)
  #   the migrations `action_agent:install` emits, by exact name after the
  #     timestamp (ENGINE_MIGRATIONS and the numbered templates)
  #   db/schema.rb or db/structure.sql
  #   app/agent_tools/<model>_tools.rb for every model the App assistant was
  #     ever given (Project#schema_tools_models), so that a file a boot
  #     removed can be removed on the branch too
  #   .activeagents/sandbox.yml and .activeagents/evals/<project>.yml
  #
  # The last two are generated here rather than read from the checkout (see
  # #generated_files): sandbox.yml holds the setup that booted the project
  # and the names of its secrets, never their values, and the evaluation
  # suite holds the project evaluation's enabled scenarios in the shape
  # ActiveAgent::Evals::Suite.load reads. Anything else the sandbox changed,
  # .github/ and any file holding one of the project's secrets is refused by
  # the publisher.
  #
  # A publish takes every REQUIRED_PATHS file and engine migration the
  # sandbox changed (#missing_required_paths): every boot of the branch
  # installs nothing, so it boots only with all of them.
  class ProjectInstallPullRequest
    SANDBOX_CONFIG = ".activeagents/sandbox.yml"
    STATIC_PATHS = [
      "Gemfile", "Gemfile.lock", "config/initializers/action_agent.rb", "config/routes.rb", "db/schema.rb", "db/structure.sql",
      SANDBOX_CONFIG
    ].freeze
    # What `active_agent:install` writes into a repository without the
    # framework.
    FRAMEWORK_PATHS = %w[config/active_agent.yml app/agents/application_agent.rb].freeze
    # The migrations `action_agent:install` emits by name, beside its
    # numbered templates (ActionAgent::InstallGenerator).
    ENGINE_MIGRATIONS = %w[
      create_active_agent_telemetry_traces add_agent_id_to_active_agent_telemetry_traces add_agent_releases
      create_active_agent_dashboard_tables ensure_agent_release_columns create_active_agent_evaluation_scenarios
      add_evaluation_report_identity add_provider_key_api_key create_active_agent_github_connections
      create_active_agent_code_sessions add_code_session_runner
    ].freeze
    # What a boot of the branch, which installs nothing, needs to load the
    # engine.
    REQUIRED_PATHS = [
      "Gemfile", "Gemfile.lock", "config/initializers/action_agent.rb", "config/routes.rb", "db/schema.rb", "db/structure.sql"
    ].freeze
    NUMBERED_MIGRATION = /\A\d{3}_(?<name>[a-z0-9_]+)\.rb\.erb\z/
    NUMBERED_MIGRATIONS_PATH = File.expand_path("../../../lib/generators/action_agent/templates/migrations", __dir__)
    DEFAULT_BRANCH = "activeagent/install-engine"
    DEFAULT_SETUP = [ "bundle install", "bin/rails db:prepare" ].freeze

    class << self
      # The names of every migration `action_agent:install` emits.
      def engine_migration_names
        numbered = Dir.children(NUMBERED_MIGRATIONS_PATH).sort.filter_map { |file| NUMBERED_MIGRATION.match(file)&.[](:name) }
        ENGINE_MIGRATIONS + numbered
      rescue Errno::ENOENT
        ENGINE_MIGRATIONS
      end

      # The publisher a queued +record+ is published with: the project's,
      # with its generated files, when +record+ is a project's install pull
      # request, and a plain one otherwise.
      def publisher_for(record, user: nil)
        project = record.sandbox_session&.project
        if project && project.settings["install_pull_request_id"] == record.id
          new(project, user: user).publisher(record.sandbox_session)
        else
          DraftPullRequestPublisher.new(record.sandbox_session, user: user)
        end
      end
    end

    attr_reader :project

    def initialize(project, user: nil, orchestrator: SandboxOrchestrator.new)
      @project = project
      @user = user
      @orchestrator = orchestrator
    end

    # The patterns DraftPullRequestPublisher#changes takes for the project.
    #
    # @return [Array<String, Regexp>]
    def allowlist
      paths = STATIC_PATHS.dup
      paths.concat(FRAMEWORK_PATHS) if framework_generated?
      paths.concat(project.schema_tools_models.map { |model| "#{SandboxBootSpec::SCHEMA_TOOLS_DIR}/#{model.underscore}_tools.rb" })
      paths << evaluation_path
      paths << engine_migration_pattern
      paths
    end

    # The REQUIRED_PATHS and engine migrations +publisher+'s sandbox changed
    # that +paths+ leaves out.
    #
    # @return [Array<String>]
    def missing_required_paths(publisher, paths)
      chosen = paths.to_set
      publisher.changed_paths.select do |path|
        (REQUIRED_PATHS.include?(path) || engine_migration_pattern.match?(path)) && !chosen.include?(path)
      end
    end

    # Where the project evaluation's suite is published.
    def evaluation_path
      ".activeagents/evals/#{project.name.parameterize.presence || "project-#{project.id}"}.yml"
    end

    # The publisher for +sandbox+ with the project's generated files.
    def publisher(sandbox = project.current_sandbox_session)
      DraftPullRequestPublisher.new(sandbox, user: @user, orchestrator: @orchestrator, generated_files: generated_files(sandbox))
    end

    # What the dashboard writes itself: sandbox.yml, and the evaluation
    # suite when the project's evaluation has enabled scenarios.
    #
    # @return [Hash{String => String}]
    def generated_files(sandbox = project.current_sandbox_session)
      files = { SANDBOX_CONFIG => sandbox_config(sandbox) }
      suite = evaluation_suite
      files[evaluation_path] = suite if suite
      files
    end

    # The project's sandbox.yml: the checkout's own, if it has one, with the
    # setup that booted the project and the names of the project's secrets.
    # The values the setup assistant set are not secrets, and stay with the
    # project: a boot passes them as env.
    def sandbox_config(sandbox)
      data = base_sandbox_config(sandbox)
      data["setup"] = setup_commands(sandbox)
      names = Array(data["secrets"]).map(&:to_s) | project.secrets.ordered.reject(&:plain?).map(&:name)
      data["secrets"] = names if names.any?

      <<~YAML + data.to_yaml.delete_prefix("---\n")
        # How an ActiveAgent checkout sandbox boots this app: the setup commands,
        # and the names of the environment variables it needs. Their values are
        # never written here: a sandbox is given them when it boots.
      YAML
    end

    # The project evaluation's enabled scenarios as an evaluation suite
    # (ActiveAgent::Evals::Suite), grouped as the dashboard groups them; nil
    # when there are none.
    def evaluation_suite
      evaluation = project.evaluation
      scenarios = evaluation ? evaluation.scenarios.enabled.ordered.to_a : []
      return nil if scenarios.empty?

      groups = scenarios.group_by { |scenario| scenario.group.presence || "default" }.map do |group, members|
        { "key" => group, "name" => group, "scenarios" => members.map { |scenario| suite_entry(scenario) } }
      end
      document = {
        "suite" => evaluation_path.delete_prefix(".activeagents/evals/").delete_suffix(".yml"),
        "description" => "#{evaluation.name}: the scenarios #{project.repository}'s project evaluation replays",
        "groups" => groups
      }
      document.to_yaml
    end

    private

    def engine_migration_pattern
      @engine_migration_pattern ||= begin
        names = self.class.engine_migration_names.map { |name| Regexp.escape(name) }.join("|")
        %r{\Adb/migrate/\d+_(?:#{names})\.rb\z}
      end
    end

    # Whether the bootstrap wrote the framework's files: the repository's
    # lock had no activeagent when the project picked it.
    def framework_generated?
      project.settings.dig("preflight", "activeagent").blank?
    end

    def suite_entry(scenario)
      expect = {
        "tools" => scenario.expected_tools.presence,
        "contains" => scenario.expected_patterns.presence,
        "not_contains" => scenario.forbidden_patterns.presence
      }.compact
      { "key" => scenario.key, "prompt" => scenario.prompt, "expect" => expect.presence, "notes" => scenario.notes.presence }.compact
    end

    def base_sandbox_config(sandbox)
      content = sandbox && @orchestrator.read_file(sandbox, SANDBOX_CONFIG, base: true)
      data = content ? YAML.safe_load(content.force_encoding(Encoding::UTF_8), aliases: false) : nil
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    # The commands of the boot steps that succeeded, as the checkout's own
    # sandbox.yml boot runs them: without the steps that installed the
    # engine and wrote the schema tools, which the pull request carries.
    def setup_commands(sandbox)
      status = sandbox && @orchestrator.supports?(:boot_status) ? @orchestrator.boot_status(sandbox) : nil
      succeeded = Array(status&.dig(:steps)).filter_map { |step| step[:name] if step[:status] == "succeeded" }.to_set
      commands = project.boot_spec(sandbox).steps.filter_map do |step|
        next if SandboxBootSpec::INSTALL_STEPS.include?(step["name"]) || SandboxBootSpec.schema_tools_step?(step["name"])

        step["command"] if succeeded.include?(step["name"])
      end
      commands.presence || DEFAULT_SETUP.dup
    rescue StandardError
      DEFAULT_SETUP.dup
    end
  end
end
