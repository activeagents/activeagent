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

      before_action :require_execution_enabled!, only: [ :run, :compare ]
      # A checkout runs the owner's code (setup, server): the same gates as
      # running an agent, like MCPServersController#launch.
      before_action :gate_checkout!, only: [ :create ]
      before_action :enforce_execution_quota!, only: [ :compare ]
      before_action :set_sandbox, only: [ :show, :run, :destroy ]

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
          # Found through the key's own owner column, as
          # SandboxSession#runtime_environment finds the credential it hands a
          # checkout: a provider key is account-owned before user-owned.
          claude_code_connected: owned(ProviderKey).exists?(provider: "claude_code")
        }
      end

      def gate_checkout!
        return unless params[:sandbox_type].to_s == "app_runtime"

        require_execution_enabled!
        return if performed?

        enforce_execution_quota!
        record_execution_usage unless performed?
      end

      # POST /api/sandboxes
      # Create a new sandbox session, owned by whoever opened it.
      def create
        @sandbox = SandboxSession.new(sandbox_params)
        # Guarded: the association only exists when the host app configured a
        # user model, and a single-user install configures none.
        @sandbox.user = current_user if @sandbox.respond_to?(:user=)
        # A checkout is validated against the owner's GitHub connection, which
        # an account-owned install finds through the account.
        @sandbox.account_id = current_account.id if current_account && @sandbox.has_attribute?(:account_id)
        @sandbox.agent_template = AgentTemplate.find_by(slug: params[:template_slug]) if params[:template_slug]

        if @sandbox.save
          @sandbox.provision!
          @sandbox.reload # Reload to get updated status after provisioning
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
        @sandbox = owned(SandboxSession).find_by!(session_id: params[:id])
      end

      # Whether the configured backend can run Claude Code sessions. A
      # backend that cannot even be loaded (a misspelled class in
      # ActionAgent.sandbox_backends, or a class file requiring an SDK the
      # host doesn't bundle, which raises LoadError) cannot, and must not
      # take the rest of this listing down with it.
      def code_sessions_supported?
        SandboxOrchestrator.new.supports?(:code_session)
      rescue StandardError, LoadError => e
        Rails.logger.warn("[ActionAgent] sandbox backend unavailable: #{e.message}")
        false
      end

      # The caller's sandboxes that have not expired, newest first. A failed
      # one stays listed so its error can be read; one past its expiry but
      # not reaped yet stays listed so it can still be stopped.
      def listed_sandboxes
        scope = owned(SandboxSession).where.not(status: :expired).recent.limit(20)
        type = params[:sandbox_type]
        type.is_a?(String) && type.present? ? scope.by_type(type) : scope
      end

      # An app_runtime sandbox also names the checkout: one of the owner's
      # selected GitHub repositories and, optionally, a ref.
      def sandbox_params
        params.permit(:sandbox_type, :repository, :repository_ref)
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
