# frozen_string_literal: true

module ActionAgent
  module Api
    class SandboxesController < BaseController
      # Authenticated like the rest of the dashboard. This controller used to
      # opt out entirely for an anonymous free tier, which made #run and
      # #compare an open proxy: any unauthenticated caller could execute
      # arbitrary prompts against the host app's provider credentials, and
      # #show would read back any session by id. Opting out also skipped the
      # callback that refuses to serve an unauthenticated dashboard outside
      # development, so it bypassed that safeguard too.

      # What POST /api/sandboxes takes for a checkout's boot (see #create).
      BOOT_OPTIONS = %i[bootstrap start_url keep_on_failure].freeze
      BOOT_LOG_PAGE_BYTES = 64 * 1024
      BOOT_LOG_MAX_PAGE_BYTES = 1024 * 1024

      # Declared once per method: Rails replaces an earlier callback for the
      # same method whatever its `only:`, so a second declaration would ungate
      # the first one's actions.
      before_action :require_execution_enabled!, only: [ :run, :compare, :resume_boot ]
      # A checkout runs the owner's code (setup, server): the same gates as
      # running an agent, like MCPServersController#launch.
      before_action :gate_checkout!, only: [ :create ]
      # A resume runs the checkout's code again, so it answers to the quota,
      # but continues the boot its create already counted and spends nothing.
      before_action :enforce_execution_quota!, only: [ :compare, :resume_boot ]
      before_action :set_sandbox, only: [ :show, :run, :destroy, :boot, :boot_log, :resume_boot ]

      # POST /api/sandboxes/compare
      # Run multiple providers in a single sandbox using parallel generation jobs
      def compare
        providers = params[:providers].nil? ? %w[anthropic openai ollama] : params[:providers]
        task = params[:task]
        sandbox_id = params[:sandbox_id]

        return render json: { error: "Task required" }, status: :bad_request unless task.present?
        # A bare string or a nested object is a malformed request, not a list
        # of one provider: reading it as a list raised NoMethodError.
        unless providers.is_a?(Array) && providers.all? { |name| name.is_a?(String) }
          return render json: { error: "providers must be a list of provider names" }, status: :bad_request
        end
        return render json: { error: "At least 2 providers required" }, status: :bad_request if providers.size < 2

        # Validate providers
        invalid = providers - %w[anthropic openai ollama]
        return render json: { error: "Invalid providers: #{invalid.join(', ')}" }, status: :bad_request if invalid.any?

        # Use existing sandbox or create a new one (single container per user)
        sandbox = if sandbox_id.present?
          owned(SandboxSession).find_by!(session_id: sandbox_id)
        else
          s = SandboxSession.new(sandbox_type: params[:sandbox_type] || "playwright_mcp")
          s.user = current_user if s.respond_to?(:user=)
          s.save!
          s.provision!
          s.reload
          s
        end

        unless sandbox.can_run?
          return render json: {
            error: sandbox.expired? ? "Session expired" : "Maximum runs exceeded",
            sandbox: sandbox.summary
          }, status: :unprocessable_entity
        end

        sandbox.update!(status: :running)
        comparison_id = SecureRandom.uuid

        # One execution per provider. Recorded before the jobs are enqueued,
        # mirroring #run's record-before-enqueue order, so usage is counted
        # even if a later enqueue raises. Without this the quota gate on
        # compare was checked but never advanced: comparisons were free.
        providers.size.times { record_execution_usage }

        # Spawn a separate generation job for each provider (all in same sandbox)
        runs = providers.map do |provider|
          run_id = SecureRandom.uuid
          SandboxRunJob.perform_later(sandbox.id, run_id, task, provider)

          {
            provider: provider,
            run_id: run_id,
            status: "running"
          }
        end

        render json: {
          comparison_id: comparison_id,
          task: task,
          sandbox: sandbox.summary,
          runs: runs
        }, status: :accepted
      end

      # GET /api/sandboxes
      # List available sandbox types and sample tasks, and the caller's own
      # sandboxes (?sandbox_type= narrows them), with what the Settings ->
      # Integrations view needs to offer Claude Code sessions in a checkout.
      def index
        render json: {
          sandbox_types: SandboxSession::SANDBOX_TYPES,
          free_tier_limits: SandboxSession::FREE_TIER_LIMITS,
          templates: free_tier_templates,
          sample_tasks: sample_tasks,
          sandboxes: listed_sandboxes.map(&:summary),
          code_sessions_supported: code_sessions_supported?,
          codex_sessions_supported: codex_sessions_supported?,
          codex_connected: owned(ProviderKey).where(provider: "codex").any? { |key| key.runtime_environment.present? },
          **claude_code_status
        }
      end

      # Refuses a checkout the owner may not start. Usage is recorded by
      # #create once the sandbox saved: a request refused for its own
      # content (a repository that is not selected, say) runs nothing, so it
      # must not spend a plan run.
      def gate_checkout!
        return unless checkout_requested?

        require_execution_enabled!
        enforce_execution_quota! unless performed?
      end

      # POST /api/sandboxes
      # Create a new sandbox session, owned by whoever opened it.
      #
      # A checkout also takes how it boots (see SandboxBootSpec.request_options):
      # `bootstrap` ("auto", "always" or "never"), `start_url` and
      # `keep_on_failure`.
      def create
        boot = checkout_requested? ? boot_options : nil
        return if performed?

        @sandbox = SandboxSession.new(sandbox_params)
        # Guarded: the association only exists when the host app configured a
        # user model, and a single-user install configures none.
        @sandbox.user = current_user if @sandbox.respond_to?(:user=)
        # A checkout is validated against the owner's GitHub connection, which
        # an account-owned install finds through the account.
        @sandbox.account_id = current_account.id if current_account && @sandbox.has_attribute?(:account_id)
        @sandbox.agent_template = AgentTemplate.find_by(slug: params[:template_slug]) if params[:template_slug]

        if @sandbox.save
          @sandbox.provision!(boot: boot)
          @sandbox.reload # Reload to get updated status after provisioning
          # Counted once the checkout exists, as MCPServersController#launch
          # counts a launched server.
          record_execution_usage if checkout_requested?
          render json: { sandbox: @sandbox.summary }, status: :created
        else
          render json: { errors: @sandbox.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # GET /api/sandboxes/:session_id
      # Get sandbox status and run history
      def show
        render json: { sandbox: @sandbox.details }
      end

      # POST /api/sandboxes/:session_id/run
      # Execute a task in the sandbox
      def run
        unless @sandbox.can_run?
          return render json: {
            error: @sandbox.expired? ? "Session expired" : "Maximum runs exceeded",
            sandbox: @sandbox.summary
          }, status: :unprocessable_entity
        end

        # Whatever limits the host app imposes on running an agent.
        if (denial = ActionAgent.quota_denial(current_owner, :execution))
          return render json: {
            error: "Plan limit reached",
            upgrade_required: true,
            message: denial
          }, status: :payment_required
        end

        task = params[:task]
        return render json: { error: "Task required" }, status: :bad_request unless task.present?

        # Provider selection (default to anthropic)
        provider = params[:provider] || "anthropic"
        unless %w[anthropic openai ollama].include?(provider)
          return render json: { error: "Invalid provider" }, status: :bad_request
        end

        record_execution_usage

        @sandbox.update!(status: :running)

        # Execute via job for async processing
        run_id = SecureRandom.uuid
        SandboxRunJob.perform_later(@sandbox.id, run_id, task, provider)

        render json: {
          run_id: run_id,
          status: "running",
          provider: provider,
          sandbox: @sandbox.summary
        }, status: :accepted
      end

      # GET /api/sandboxes/:session_id/boot
      # How a checkout's boot went, step by step (see
      # SandboxOrchestrator#boot_status). `boot` is null when the backend
      # reports no steps, or holds nothing for the sandbox.
      def boot
        orchestrator = SandboxOrchestrator.new
        status = @sandbox.app_runtime? && orchestrator.supports?(:boot_status) ? orchestrator.boot_status(@sandbox) : nil
        # A project's checkout booted with its secrets, which the backend may
        # not know to mask.
        status = SecretScrubber.scrub(status, @sandbox.project_scrub_values) if status && @sandbox.project_id
        render json: {
          boot: status,
          resumable: !!(status&.dig(:kept) && @sandbox.failed? && !@sandbox.past_expiry? && orchestrator.supports?(:resume_boot)),
          logs: @sandbox.app_runtime? && orchestrator.supports?(:boot_log)
        }
      end

      # GET /api/sandboxes/:session_id/boot_log?step=NAME&offset=N&limit=N
      # One page of a boot step's log, scrubbed (see
      # SandboxOrchestrator#boot_log). Read on from `next_offset` until
      # `eof`.
      def boot_log
        orchestrator = SandboxOrchestrator.new
        unless @sandbox.app_runtime? && orchestrator.supports?(:boot_log)
          return render json: { error: "This sandbox backend keeps no boot logs" }, status: :not_found
        end

        step = params[:step]
        return render json: { error: "step is required" }, status: :bad_request unless step.is_a?(String) && step.present?

        project_secrets = @sandbox.project_scrub_values
        page = orchestrator.boot_log(@sandbox, step: step, offset: clamped_param(:offset, default: 0, min: 0, max: 2**62),
          limit: clamped_param(:limit, default: BOOT_LOG_PAGE_BYTES, min: 1, max: BOOT_LOG_MAX_PAGE_BYTES), secrets: project_secrets)
        return render json: { error: "No log for step #{step}" }, status: :not_found if page.nil?

        render json: project_secrets.any? ? page.merge(text: SecretScrubber.scrub(page[:text], project_secrets)) : page
      end

      # POST /api/sandboxes/:session_id/resume_boot
      # Continues a checkout whose boot failed and was kept (`keep_on_failure`),
      # from the step named `from`, or from the one that failed. The sandbox
      # is provisioning again, and is polled until ready or failed as after
      # #create.
      def resume_boot
        orchestrator = SandboxOrchestrator.new
        unless @sandbox.app_runtime? && orchestrator.supports?(:resume_boot)
          return render json: { error: "This sandbox backend cannot resume a boot" }, status: :unprocessable_entity
        end

        from = params[:from]
        unless from.nil? || from.is_a?(String)
          return render json: { error: "from must be a step name" }, status: :bad_request
        end

        status = orchestrator.boot_status(@sandbox) if orchestrator.supports?(:boot_status)
        if orchestrator.supports?(:boot_status) && !status&.dig(:kept)
          return render json: { error: "This sandbox kept no failed boot to resume: start it again", sandbox: @sandbox.summary },
            status: :unprocessable_entity
        end

        # Refused here rather than by the backend, whose refusal would fail
        # the sandbox again and replace the error the failed boot left.
        steps = status&.dig(:resumable_steps)
        if from.present? && steps.is_a?(Array) && !steps.include?(from)
          return render json: { error: "#{from.inspect} is not a step this boot can resume from (#{steps.join(", ")})" },
            status: :unprocessable_entity
        end

        unless @sandbox.resume_boot!(from: from)
          return render json: {
            error: "Only a failed checkout that has not expired can be resumed: start it again",
            sandbox: @sandbox.summary
          }, status: :unprocessable_entity
        end

        render json: { sandbox: @sandbox.reload.summary }, status: :accepted
      end

      # DELETE /api/sandboxes/:session_id
      # End sandbox session. Expiring it enqueues SandboxCleanupJob, which
      # terminates whatever the backend runs for it (a checkout's processes
      # included); one still provisioning is released by
      # SandboxProvisionJob when its backend returns.
      def destroy
        @sandbox.expire!
        render json: { deleted: true, sandbox: @sandbox.summary }
      end

      private

      def set_sandbox
        @sandbox = account_scoped(owned(SandboxSession)).find_by!(session_id: params[:id])
      end

      def checkout_requested?
        params[:sandbox_type].to_s == "app_runtime"
      end

      # A checkout's boot options, or a rendered 422 when they are malformed
      # or ask for a bootstrap the backend cannot do.
      def boot_options
        raw = params.slice(*BOOT_OPTIONS).permit(*BOOT_OPTIONS).to_h.symbolize_keys
        options = SandboxBootSpec.request_options(**raw)
        if options["bootstrap"] == "always" && !SandboxOrchestrator.new.accepts_boot_config?
          render json: { errors: [ "This sandbox backend cannot bootstrap a checkout" ] }, status: :unprocessable_entity
          return
        end

        options
      rescue SandboxBootSpec::Invalid => e
        render json: { errors: [ e.message ] }, status: :unprocessable_entity
        nil
      end

      # A checkout runs on its account's GitHub token and Claude Code
      # credential, so in a multi-tenant install it is listed, shown and
      # stopped only within the caller's current account, as
      # CodeSessionsController finds it: listing another account's checkout
      # as Ready offered a Claude Code panel that then answered 404. Other
      # sandbox types are the caller's own wherever they were opened.
      def account_scoped(scope)
        return scope unless current_account

        scope.where.not(sandbox_type: "app_runtime").or(scope.where(account_id: current_account.id))
      end

      # Whether the configured backend can run Claude Code sessions. A
      # backend that cannot even be loaded (a misspelled class in
      # ActionAgent.sandbox_backends, or a class file requiring an SDK the
      # host doesn't bundle, which raises LoadError) cannot, and must not
      # take the rest of this listing down with it.
      #
      # Nor can one whose Claude Code authentication does not work there
      # (ActionAgent.claude_code_auth = :local_login needs :local).
      def code_sessions_supported?
        orchestrator = SandboxOrchestrator.new
        orchestrator.supports?(:code_session) && ClaudeCodeAuth.backend_refusal(orchestrator).nil?
      rescue StandardError, LoadError => e
        Rails.logger.warn("[ActionAgent] sandbox backend unavailable: #{e.message}")
        false
      end

      def codex_sessions_supported?
        SandboxOrchestrator.new.supports_code_runner?("codex")
      rescue StandardError, LoadError
        false
      end

      # Whether the caller's Claude Code can run sessions, by
      # ClaudeCodeAuth's rule: an API key they connected, or this machine's
      # own login. Never a credential.
      #
      #   claude_code_auth       "api_key" | "local_login"
      #   claude_code_connected  Boolean
      #   claude_code_login      { logged_in:, auth_method: } (local_login only)
      #
      # The key is found through its own owner column, as
      # SandboxSession#runtime_environment finds the credential it hands a
      # checkout: a provider key is account-owned before user-owned.
      def claude_code_status
        status = ClaudeCodeAuth.status(owned(ProviderKey))
        {
          claude_code_auth: status[:mode],
          claude_code_connected: status[:connected],
          claude_code_login: status[:login]
        }.compact
      end

      # The caller's sandboxes that have not expired, newest first. A failed
      # one stays listed so its error can be read; one past its expiry but
      # not reaped yet stays listed so it can still be stopped.
      def listed_sandboxes
        scope = account_scoped(owned(SandboxSession)).where.not(status: :expired).recent.limit(20)
        type = params[:sandbox_type]
        type.is_a?(String) && type.present? ? scope.by_type(type) : scope
      end

      # An app_runtime sandbox also names the checkout: one of the owner's
      # selected GitHub repositories and, optionally, a ref.
      def sandbox_params
        params.slice(:sandbox_type, :repository, :repository_ref).permit(:sandbox_type, :repository, :repository_ref)
      end

      def free_tier_templates
        AgentTemplate.free_tier.featured.map do |template|
          {
            slug: template.slug,
            name: template.name,
            description: template.description,
            icon: template.icon,
            sandbox_type: template.preset_type == "playwright" ? "playwright_mcp" : template.preset_type
          }
        end
      end

      def sample_tasks
        {
          playwright_mcp: [
            {
              name: "Screenshot Example.com",
              task: "Take a screenshot of https://example.com",
              description: "Navigate to example.com and capture a screenshot"
            },
            {
              name: "Extract Hacker News Headlines",
              task: "Go to https://news.ycombinator.com and list the top 5 story titles with their scores",
              description: "Scrape the front page of Hacker News"
            },
            {
              name: "Check Wikipedia",
              task: "Navigate to https://en.wikipedia.org/wiki/Artificial_intelligence and extract the first paragraph",
              description: "Extract content from Wikipedia"
            },
            {
              name: "GitHub Trending",
              task: "Visit https://github.com/trending and list the top 3 trending repositories",
              description: "Check GitHub's trending repositories"
            }
          ],
          terminal: [
            {
              name: "System Info",
              task: "Show the current system information",
              description: "Display OS, memory, and CPU details"
            }
          ],
          research: [
            {
              name: "Topic Summary",
              task: "Research and summarize the latest developments in AI",
              description: "Search and compile information on a topic"
            }
          ]
        }
      end
    end
  end
end
