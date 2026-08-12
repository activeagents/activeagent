# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    module Api
      class SandboxesController < BaseController
        # Allow anonymous access to sandbox API for free tier
        allow_unauthenticated_access

        before_action :set_sandbox, only: [ :show, :run, :destroy ]

        # POST /api/sandboxes/compare
        # Run multiple providers in a single sandbox using parallel generation jobs
        def compare
          providers = params[:providers] || %w[anthropic openai ollama]
          task = params[:task]
          sandbox_id = params[:sandbox_id]

          return render json: { error: "Task required" }, status: :bad_request unless task.present?
          return render json: { error: "At least 2 providers required" }, status: :bad_request if providers.size < 2

          # Validate providers
          invalid = providers - %w[anthropic openai ollama]
          return render json: { error: "Invalid providers: #{invalid.join(', ')}" }, status: :bad_request if invalid.any?

          # Use existing sandbox or create a new one (single container per user)
          sandbox = if sandbox_id.present?
            SandboxSession.find_by!(session_id: sandbox_id)
          else
            s = SandboxSession.create!(
              sandbox_type: params[:sandbox_type] || "playwright_mcp",
              user: current_user
            )
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
        # List available sandbox types and sample tasks
        def index
          render json: {
            sandbox_types: SandboxSession::SANDBOX_TYPES,
            free_tier_limits: SandboxSession::FREE_TIER_LIMITS,
            templates: free_tier_templates,
            sample_tasks: sample_tasks
          }
        end

        # POST /api/sandboxes
        # Create a new sandbox session (no auth required for free tier)
        def create
          @sandbox = SandboxSession.new(sandbox_params)
          @sandbox.user = current_user # nil for anonymous users
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
          if (denial = ActiveAgent::Dashboard.quota_denial(current_owner, :execution))
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
        # End sandbox session
        def destroy
          @sandbox.expire!
          render json: { deleted: true }
        end

        private

        def set_sandbox
          @sandbox = SandboxSession.find_by!(session_id: params[:id])
        end

        def sandbox_params
          params.permit(:sandbox_type)
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
end
