# frozen_string_literal: true

module ActionAgent
  module Api
    # Projects: picking a repository, checking it can boot, creating the
    # project with the secrets its boot needs, following each boot, choosing
    # the agent to evaluate and running the project's evaluation against the
    # booted app. See Project.
    #
    # Everything is scoped to the caller's owner. The project's sandbox and
    # agent carry the project's owner columns, so they are reached through
    # the project here rather than through the sandboxes and agents APIs,
    # which scope to the signed-in user.
    class ProjectsController < BaseController
      include ProjectSecretAuthorization

      LOG_TAIL_BYTES = 8 * 1024
      LOG_PAGE_BYTES = 64 * 1024
      LOG_MAX_PAGE_BYTES = 1024 * 1024
      UPDATABLE = %i[name default_ref start_url].freeze

      before_action :require_owner!
      before_action :set_project, except: [ :index, :create, :capabilities, :preflight, :discover_secrets ]
      before_action :require_execution_enabled!, only: [ :boot, :run_evaluation ]

      # Later handlers win, so subclasses are registered after GithubClient::Error.
      rescue_from GithubClient::Error, with: :github_unavailable
      rescue_from GithubClient::NotFound, with: :github_not_found
      rescue_from GithubClient::Unauthorized, with: :github_unauthorized
      rescue_from Project::ConfirmationRequired, with: :confirmation_required
      rescue_from Project::BootRefused, with: :boot_refused
      rescue_from SandboxOrchestrator::UnsupportedBackendError, with: :boot_refused

      # GET /api/projects
      def index
        projects = owned(Project).recent.includes(:current_sandbox_session, :target_agent, :evaluation, :secrets)
        render json: { projects: projects.map(&:summary) }
      end

      # GET /api/projects/:id
      def show
        render json: { project: @project.summary, secrets: secret_summaries(@project) }
      end

      # GET /api/projects/capabilities
      # The New Project checklist (see ProjectCapabilities).
      def capabilities
        render json: capabilities_check.call
      end

      # GET /api/projects/preflight?repository=owner/name&ref=
      # Whether the repository can become a project, read through GitHub's
      # contents API before any sandbox exists (see ProjectPreflight). A
      # repository the connection has not selected is looked up by name,
      # which also reaches repositories past the listing's cap, and needs
      # :manage_github.
      def preflight
        connection = github_connection! or return
        repository = reachable_repository!(connection) or return

        ref = ref_param || repository["default_branch"]
        render json: {
          repository: repository.merge("selected" => connection.repository(repository["full_name"]).present?),
          preflight: ProjectPreflight.call(connection.client, repository: repository["full_name"], ref: ref)
        }
      end

      # GET /api/projects/discover_secrets?repository=owner/name&ref=
      # The environment variables the repository expects (see
      # ProjectSecretDiscovery), each marked with whether the project named by
      # `project_id`, if any, has it set. A repository the connection has not
      # selected needs :manage_github, as for preflight.
      def discover_secrets
        connection = github_connection! or return
        repository = reachable_repository!(connection) or return

        discovery = ProjectSecretDiscovery.call(connection.client, repository: repository["full_name"],
          ref: ref_param || repository["default_branch"])
        set = params[:project_id].present? ? owned(Project).find(params[:project_id]).secrets.pluck(:name).to_set : Set.new
        discovery[:variables].each { |variable| variable[:set] = set.include?(variable[:name]) }
        render json: discovery
      end

      # POST /api/projects
      # { repository:, name:, default_ref:, start_url:, secrets: [{ name:, value: } |
      #   { name:, source: "organization_key", consent: true }] }
      #
      # Refused while a blocking capability fails, when the host's quota
      # denies a :project, and for a repository the preflight does not
      # support. Picking a repository the GitHub connection has not selected
      # selects it, which needs :manage_github.
      def create
        failures = capabilities_check.blocking_failures
        if failures.any?
          return render json: { error: "This dashboard cannot create projects yet: #{failures.map { |item| item[:label] }.join(", ")}",
                                code: "capabilities", items: failures }, status: :unprocessable_entity
        end
        return if quota_denied?

        connection = github_connection! or return
        repository = reachable_repository!(connection) or return
        full_name = repository["full_name"]
        ref = ref_param
        report = ProjectPreflight.call(connection.client, repository: full_name, ref: ref || repository["default_branch"])
        if report["status"] == "unsupported"
          return render json: { error: report["summary"], code: "unsupported_repository", preflight: report },
            status: :unprocessable_entity
        end

        secrets = params[:secrets] || []
        return render json: { error: "secrets must be a list" }, status: :bad_request unless secrets.is_a?(Array)

        project = build_project(full_name, ref, report)
        return unless secret_sources_allowed!(secrets)
        return unless authorize_secrets!(project, secrets)

        selecting = connection.repository(full_name).nil?
        Project.transaction do
          # The selection is what a project's sandbox is booted from.
          connection.update!(repositories: connection.repositories + [ repository ]) if selecting
          project.save!
          secrets.each { |attributes| assign_secret_params(project, attributes).save! }
          project.ensure_app_assistant! unless project.engine_installed?
        end
        ActionAgent.record_usage(current_owner, :project)

        render json: { project: project.reload.summary, secrets: secret_summaries(project) }, status: :created
      end

      # PATCH /api/projects/:id { name:, default_ref:, start_url: }
      #
      # A new default_ref (empty for the repository's default branch) is
      # preflighted like a new project's repository and refused when not
      # supported. The next boot hands the project's secrets to the code at
      # that ref, so changing it needs what setting each secret needs, and
      # stops the sandbox booted from the old ref (see Project#change_ref!).
      def update
        attributes = params.permit(*UPDATABLE).to_h
        if attributes.key?("default_ref")
          ref, report = new_ref(attributes.delete("default_ref").to_s)
          return if performed?
        end

        @project.assign_attributes(attributes)
        report ? @project.change_ref!(ref, report) : @project.save!
        render json: { project: @project.reload.summary }
      end

      # DELETE /api/projects/:id
      # Deletes the project, its secrets, its agent and evaluation, and stops
      # its sandbox. Deleting its secrets needs :manage_project_secrets.
      def destroy
        return unless authorize_secrets_removal!(@project)

        @project.discard!
        head :no_content
      end

      # POST /api/projects/:id/boot { confirm: true }
      # Returns the project's sandbox, booting one when there is none live
      # (see Project#ensure_sandbox!). A first boot on the :local backend
      # answers 409 with the question to confirm, and is asked again with
      # `confirm: true`.
      def boot
        return if execution_quota_denied?

        sandbox, booted = ensure_project_sandbox!
        return if performed?

        render json: { project: @project.reload.summary, sandbox: sandbox.summary, booted: booted },
          status: booted ? :accepted : :ok
      end

      # GET /api/projects/:id/boot
      # The current sandbox's boot, step by step (see
      # SandboxOrchestrator#boot_status), with the scrubbed tail of the step
      # that failed or is running.
      def boot_status
        sandbox = @project.current_sandbox_session
        orchestrator = SandboxOrchestrator.new
        status = sandbox && orchestrator.supports?(:boot_status) ? orchestrator.boot_status(sandbox) : nil
        status = SecretScrubber.scrub(status.deep_symbolize_keys, @project.scrub_values) if status.is_a?(Hash)

        render json: {
          project: @project.summary,
          boot: status,
          log_tail: status && log_tail(orchestrator, sandbox, status),
          error: sandbox&.failed? ? SecretScrubber.scrub(sandbox.error_summary, @project.scrub_values) : nil,
          logs: sandbox.present? && orchestrator.supports?(:boot_log),
          confirmation: @project.local_boot_confirmation(orchestrator)
        }
      end

      # GET /api/projects/:id/boot_log?step=NAME&offset=N&limit=N
      # One page of a boot step's log, scrubbed of the project's secrets.
      def boot_log
        sandbox = @project.current_sandbox_session
        orchestrator = SandboxOrchestrator.new
        unless sandbox && orchestrator.supports?(:boot_log)
          return render json: { error: "This project's sandbox keeps no boot logs" }, status: :not_found
        end

        step = params[:step]
        return render json: { error: "step is required" }, status: :bad_request unless step.is_a?(String) && step.present?

        page = orchestrator.boot_log(sandbox, step: step, offset: clamped_param(:offset, default: 0, min: 0, max: 2**62),
          limit: clamped_param(:limit, default: LOG_PAGE_BYTES, min: 1, max: LOG_MAX_PAGE_BYTES), secrets: @project.scrub_values)
        return render json: { error: "No log for step #{step}" }, status: :not_found if page.nil?

        render json: page.merge(text: SecretScrubber.scrub(page[:text], @project.scrub_values))
      end

      # GET /api/projects/:id/synced_agents
      # The checkout's own agents, as its running sandbox's MCP facade lists
      # them (one run_<slug> tool each).
      def synced_agents
        agents = listed_synced_agents or return

        render json: { synced_agents: agents, current: @project.settings["target_slug"] }
      end

      # PATCH /api/projects/:id/target { synced_agent: "slug" } or { app_assistant: true }
      # Chooses the agent the project evaluates: one of the checkout's synced
      # agents, which its running sandbox must list, or the App assistant.
      def target
        slug = params[:synced_agent]
        if slug.present?
          agents = listed_synced_agents or return
          unless slug.is_a?(String) && agents.any? { |agent| agent[:slug] == slug }
            return render json: { error: "#{slug.to_s.truncate(64)} is not an agent the project's sandbox serves",
                                  synced_agents: agents }, status: :unprocessable_entity
          end

          @project.target_synced_agent!(slug)
        elsif ActiveModel::Type::Boolean.new.cast(params[:app_assistant])
          @project.ensure_app_assistant!
        else
          return render json: { error: "Name a synced_agent, or ask for the app_assistant" }, status: :bad_request
        end

        render json: { project: @project.reload.summary }
      end

      # POST /api/projects/:id/run_evaluation { confirm: true }
      # Runs the project's evaluation against its sandbox. An expired sandbox
      # is booted again first, and the run waits for it (ProjectEvaluationJob)
      # rather than failing.
      def run_evaluation
        unless @project.target_agent && @project.evaluation
          return render json: { error: "Choose the agent to evaluate first", code: "no_target" }, status: :conflict
        end
        return if execution_quota_denied?

        sandbox, _booted = ensure_project_sandbox!
        return if performed?

        run = @project.evaluation.evaluation_runs.create!(status: :pending,
          selection: { "project_id" => @project.id, "sandbox_id" => sandbox.session_id })
        ProjectEvaluationJob.perform_later(@project.id, run.id)

        render json: { project: @project.reload.summary, run: { id: run.id, status: run.status, evaluation_id: run.evaluation_id } },
          status: :accepted
      end

      private

      def set_project
        @project = owned(Project).find(params[:id])
      end

      def capabilities_check
        @capabilities_check ||= ProjectCapabilities.new(
          owner: current_owner,
          github_connected: owned(GithubConnection).exists?,
          base_url: "#{request.base_url}#{request.script_name}"
        )
      end

      # Renders a 402 and answers true when the host's quota denies a project.
      def quota_denied?
        denial = ActionAgent.quota_denial(current_owner, :project)
        return false if denial.blank?

        body = { error: "Plan limit reached", upgrade_required: true }
        body = denial.is_a?(Hash) ? body.merge(denial) : body.merge(message: denial)
        render json: body, status: :payment_required
        true
      end

      # Renders a 402 and answers true when the host's quota denies an
      # execution: a boot runs the repository's code.
      def execution_quota_denied?
        enforce_execution_quota!
        performed?
      end

      def github_connection!
        connection = owned(GithubConnection).first
        return connection if connection

        render json: { error: "Connect GitHub in Settings → Integrations first", code: "github_not_connected" },
          status: :unprocessable_entity
        nil
      end

      # The repository +name+ names, as the connection reaches it: from its
      # selection, else asked of GitHub by name. Renders a 403 for a
      # repository outside the selection when the caller may not manage the
      # GitHub connection, and a 404 when GitHub finds none it can reach.
      #
      # The connection's token can be one member's, reaching that member's
      # own repositories, so only the selection is shared with every member.
      # The 403 is decided before GitHub is asked, so it says nothing about
      # whether the repository exists.
      def reachable_repository!(connection, name = params[:repository])
        unless name.is_a?(String) && Project::REPOSITORY.match?(name)
          render json: { error: "repository must be owner/name" }, status: :bad_request
          return nil
        end

        selected = connection.repository(name)
        return selected if selected

        unless ActionAgent.permitted?(current_user, :manage_github, connection)
          render json: { error: "#{name} is not one of the repositories selected in Settings → Integrations, and only " \
                                "someone who may manage the GitHub connection can pick another",
                         code: "forbidden", permission: :manage_github }, status: :forbidden
          return nil
        end

        repository = connection.client.repository(name)
        return repository if repository

        render json: { error: "GitHub found no repository #{name} that this connection can reach", code: "repository_not_found" },
          status: :not_found
        nil
      end

      def ref_param
        ref = params[:ref].presence || params[:default_ref].presence
        ref.is_a?(String) ? ref : nil
      end

      # [ref, preflight report] for the default_ref +requested+ ("" for the
      # repository's default branch), or nil when the project is on it
      # already. Renders why the ref cannot be used, when it cannot.
      def new_ref(requested)
        return nil if requested == @project.default_ref.to_s
        return nil unless authorize_secret_handover!(@project)

        connection = github_connection! or return
        repository = reachable_repository!(connection, @project.repository) or return
        report = ProjectPreflight.call(connection.client, repository: @project.repository,
          ref: requested.presence || repository["default_branch"])
        if report["status"] == "unsupported"
          render json: { error: report["summary"], code: "unsupported_repository", preflight: report },
            status: :unprocessable_entity
          return nil
        end

        [ requested.presence, report ]
      end

      def build_project(full_name, ref, report)
        project = owned(Project).new(
          name: params[:name].presence || full_name,
          repository: full_name,
          default_ref: ref,
          start_url: params[:start_url].presence || "/",
          install_state: report["engine"] ? "installed" : "detected",
          settings: { "preflight" => report }
        )
        # Both columns, whichever owns the project: its sandbox and agent are
        # booted for the user who created it.
        project.user_id = current_user.id if ActionAgent.user_class.present? && current_user.respond_to?(:id)
        project.account_id = current_account.id if current_account
        project
      end

      # Answers whether the caller may set +secrets+ on the unsaved +project+;
      # renders a 403 when not.
      def authorize_secrets!(project, secrets)
        secrets.all? { |attributes| authorize_secret!(secret_subject(project, attributes)) }
      end

      # The secret +attributes+ describe, for the permission checker only: it
      # is not added to +project+'s secrets, which saving the project would
      # save with it.
      def secret_subject(project, attributes)
        attributes = attributes.respond_to?(:permit) ? attributes.slice(:name, :source).permit(:name, :source).to_h : {}
        name = attributes["name"].to_s
        organization_key = attributes["source"].to_s == "organization_key"
        ProjectSecret.new(project: project, account_id: project.account_id, user_id: project.user_id, name: name,
          source: organization_key ? "organization_key" : "entered",
          provider: organization_key ? ProjectSecret::ORGANIZATION_KEY_PROVIDERS[name] : nil)
      end

      def assign_secret_params(project, attributes)
        keys = %i[name value source consent]
        attributes = attributes.respond_to?(:permit) ? attributes.slice(*keys).permit(*keys).to_h : {}
        project.assign_secret(
          name: attributes["name"], value: attributes["value"], source: attributes["source"],
          consent: ActiveModel::Type::Boolean.new.cast(attributes["consent"]) == true, set_by: current_user
        )
      end

      def secret_summaries(project)
        records = project.secrets.ordered.to_a
        records.map { |secret| secret.as_summary(setters_for(records)) }
      end

      def setters_for(records)
        @setters_for ||= begin
          ids = records.filter_map(&:set_by_id).uniq
          user_class = ActionAgent.user_class&.safe_constantize
          ids.empty? || user_class.nil? ? {} : user_class.where(id: ids).index_by(&:id)
        end
      end

      # [sandbox, whether it was booted now]. Counted as one execution when a
      # new sandbox boots, as POST /api/sandboxes counts a checkout.
      def ensure_project_sandbox!
        before = @project.current_sandbox_session_id
        sandbox = @project.ensure_sandbox!(confirm: ActiveModel::Type::Boolean.new.cast(params[:confirm]) == true,
          confirmed_by: current_user)
        booted = sandbox.id != before
        record_execution_usage if booted
        [ sandbox, booted ]
      rescue ActiveRecord::RecordInvalid => e
        raise unless e.record.is_a?(SandboxSession)

        render json: { error: "The project's sandbox could not start: #{e.record.errors.full_messages.to_sentence}" },
          status: :unprocessable_entity
        nil
      end

      # The synced agents the project's running sandbox lists, or nil after
      # rendering why none can be listed.
      def listed_synced_agents
        entry = @project.current_sandbox_session&.runtime_server_entry
        if entry.nil?
          render json: { error: "Boot the project first: its running sandbox lists the checkout's agents", code: "sandbox_not_ready" },
            status: :conflict
          return nil
        end

        tools = MCPClient.new(url: entry[:url], label: entry[:name], headers: entry[:headers] || {}).list_tools
        Project.synced_agents(tools)
      rescue MCPClient::Error => e
        render json: { error: "The project's sandbox did not list its tools: #{SecretScrubber.scrub(e.message, @project.scrub_values)}" },
          status: :bad_gateway
        nil
      end

      # The last LOG_TAIL_BYTES of the step that failed, else of the one
      # running, else of the last that ran: { step:, text:, truncated: }.
      def log_tail(orchestrator, sandbox, status)
        return nil unless orchestrator.supports?(:boot_log)

        steps = Array(status[:steps])
        step = status[:failed_step].presence ||
          steps.find { |entry| entry[:status] == "running" }&.dig(:name) ||
          steps.reverse.find { |entry| %w[succeeded failed].include?(entry[:status]) }&.dig(:name)
        return nil if step.blank?

        secrets = @project.scrub_values
        first = orchestrator.boot_log(sandbox, step: step, offset: 0, limit: 1, secrets: secrets) or return nil
        offset = [ first[:size].to_i - LOG_TAIL_BYTES, 0 ].max
        page = orchestrator.boot_log(sandbox, step: step, offset: offset, limit: LOG_TAIL_BYTES, secrets: secrets) or return nil
        text = page[:text].to_s
        # A tail that starts mid-file starts mid-line: drop the partial line.
        text = text.split("\n", 2).last.to_s if offset.positive?
        { step: step, text: SecretScrubber.scrub(text, secrets), truncated: offset.positive? }
      rescue StandardError => e
        Rails.logger.warn("[ActionAgent] project #{@project.id}: could not read the boot log: #{e.class}")
        nil
      end

      def confirmation_required(exception)
        render json: { error: exception.message, code: "confirmation_required", confirmation: exception.message },
          status: :conflict
      end

      def boot_refused(exception)
        render json: { error: exception.message, code: "boot_refused" }, status: :unprocessable_entity
      end

      def github_unauthorized
        render json: { error: "GitHub rejected the stored token. Reconnect GitHub.", reconnect_required: true },
          status: :unprocessable_entity
      end

      def github_not_found(exception)
        render json: { error: exception.message, code: "not_found" }, status: :not_found
      end

      def github_unavailable(exception)
        render json: { error: exception.message }, status: :bad_gateway
      end
    end
  end
end
