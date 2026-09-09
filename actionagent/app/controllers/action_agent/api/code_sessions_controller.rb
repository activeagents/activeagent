# frozen_string_literal: true

module ActionAgent
  module Api
    # Code sessions: handing one of the owner's agents, together with what
    # its evaluations found, to a coding agent running in a sandbox.
    #
    # Starting or running a session executes a coding agent against a
    # provider, so it is gated exactly as AgentsController#execute and a
    # scenario evaluation are: the dashboard's execution switch, no observed
    # (read-only) agents, and the host app's execution quota, with one
    # execution recorded per run.
    class CodeSessionsController < BaseController
      before_action :require_owner!
      before_action :require_execution_enabled!, only: [ :create, :run ]
      before_action :require_executable_agent!, only: [ :create ]
      before_action :enforce_execution_quota!, only: [ :create, :run ]
      before_action :set_session, only: [ :show, :run, :stop, :destroy, :brief, :events ]

      # GET /api/code_sessions
      def index
        sessions = owned(CodeSession).includes(:agent).recent.limit(50)

        render json: {
          sessions: sessions.map(&:as_json_summary),
          backend: backend_info,
          github_configured: github_configured?
        }
      end

      # GET /api/code_sessions/catalog
      #
      # What the New Code Session form is built from: which coding agents
      # this install's backend can actually launch (and why not, when it
      # cannot), the backends registered, and the host app's limits.
      def catalog
        supported = orchestrator.supported_tools

        render json: {
          tools: CodeAgentCatalog.all.map { |entry| catalog_entry(entry, supported) },
          backends: CodeSessionOrchestrator.backends.keys,
          default_backend: CodeSessionOrchestrator.default_backend,
          network_modes: CodeSession::NETWORK_MODES,
          github_access_modes: CodeSession::GITHUB_ACCESS,
          github_configured: github_configured?,
          limits: ActionAgent.code_session_limits,
          backend_info: backend_info
        }
      end

      # POST /api/code_sessions/preview_brief
      #
      # The brief the session would get, without creating one, so the form
      # can show what the coding agent will be told before anything runs.
      def preview_brief
        agent = requested_agent
        brief = build_brief(agent, evaluation_run_for(agent))

        render json: { brief: brief.to_h, markdown: brief.to_markdown }
      end

      # POST /api/code_sessions
      def create
        agent = requested_agent
        run = evaluation_run_for(agent)

        if (denial = capacity_denial)
          return render json: { error: denial }, status: :unprocessable_entity
        end

        session = CodeSession.new(
          agent: agent,
          evaluation_run: run,
          tool: code_session_params[:tool].to_s,
          backend: code_session_params[:backend].presence || CodeSessionOrchestrator.default_backend,
          repository: code_session_params[:repository],
          branch: code_session_params[:branch],
          github_access: code_session_params[:github_access].presence || "none",
          network_mode: code_session_params[:network_mode].presence || "restricted",
          model: code_session_params[:model]
        )
        # A session belongs to whoever opened it, the way a sandbox does:
        # both columns are set when the host app has them, and a single-user
        # install declares neither association. respond_to? alone is not
        # enough, because the association is declared from configuration
        # while the column comes from the host app's own table.
        assign_owner(session, :user, current_user)
        assign_owner(session, :account, current_account)

        unless backend_supports?(session)
          return render json: {
            error: "#{CodeAgentCatalog.display_name(session.tool)} cannot be launched by the #{session.backend} backend"
          }, status: :unprocessable_entity
        end

        brief = build_brief(agent, run, session: session)
        session.brief = brief.to_h
        session.task = code_session_params[:task].presence || brief.task

        if session.save
          record_execution_usage if run_requested?
          CodeSessionProvisionJob.perform_later(session.id, run_requested?)
          render json: { session: session.as_json_summary }, status: :created
        else
          render json: { errors: session.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # GET /api/code_sessions/:id
      def show
        render json: { session: detail(@session) }
      end

      # GET /api/code_sessions/:id/brief
      def brief
        render json: {
          brief: @session.brief,
          markdown: CodeSessionBrief.markdown_for(@session.brief, session: @session)
        }
      end

      # GET /api/code_sessions/:id/events
      #
      # The poll target while a session provisions or runs: everything that
      # changes, and nothing that does not.
      def events
        render json: {
          status: @session.status,
          events: @session.events,
          transcript: @session.transcript,
          exit_code: @session.exit_code,
          error_message: @session.error_message,
          input_tokens: @session.input_tokens,
          output_tokens: @session.output_tokens,
          updated_at: @session.updated_at.iso8601
        }
      end

      # POST /api/code_sessions/:id/run
      def run
        unless @session.can_run?
          return render json: {
            error: @session.expired_by_time? ? "This session has expired" : "This session is not ready to run",
            session: @session.as_json_summary
          }, status: :unprocessable_entity
        end

        prompt = params[:prompt].presence
        record_execution_usage
        @session.update!(status: :running, last_activity_at: Time.current)
        @session.append_event(kind: "run", label: "Run queued", status: "started")
        CodeSessionRunJob.perform_later(@session.id, prompt)

        render json: { session: @session.as_json_summary }, status: :accepted
      end

      # POST /api/code_sessions/:id/stop
      def stop
        @session.update!(status: :stopped, completed_at: @session.completed_at || Time.current)
        @session.append_event(kind: "session", label: "Stopped by #{actor_label}")
        CodeSessionCleanupJob.perform_later(@session.id)

        render json: { session: @session.as_json_summary }
      end

      # DELETE /api/code_sessions/:id
      def destroy
        # Terminated inline rather than through the job: the row is about to
        # be gone, so a job that looked it up afterwards would find nothing
        # and leave the container and its secrets behind.
        begin
          CodeSessionOrchestrator.new(backend: @session.backend).terminate(@session)
        rescue StandardError => e
          Rails.logger.warn("[ActionAgent] could not terminate code session #{@session.id}: #{e.message}")
        end

        @session.destroy!
        head :no_content
      end

      private

      def set_session
        @session = owned(CodeSession).find(params[:id])
      end

      def detail(session)
        session.as_json_summary.merge(
          brief: session.brief,
          events: session.events,
          transcript: session.transcript,
          attach_command: attach_command(session)
        )
      end

      def attach_command(session)
        CodeSessionOrchestrator.new(backend: session.backend).attach_command(session)
      rescue StandardError
        nil
      end

      def orchestrator
        @orchestrator ||= CodeSessionOrchestrator.new
      end

      # How long a backend health check is trusted for. Probing the real
      # backend shells out to `coi health`, over ssh on the hosted platform,
      # and both the session list and the catalog ask for it — so an
      # unavailable host would otherwise cost every page load a network
      # timeout.
      HEALTH_TTL = 60.seconds

      def backend_info
        {
          name: orchestrator.backend_name,
          class: orchestrator.backend.class.name,
          healthy: cached_health(orchestrator.backend_name),
          features: orchestrator.features
        }
      rescue StandardError => e
        Rails.logger.warn("[ActionAgent] code session backend info failed: #{e.message}")
        { name: CodeSessionOrchestrator.default_backend, healthy: false, features: {} }
      end

      # Rails.cache is a null store in some installs, which simply means the
      # check runs every time rather than failing.
      def cached_health(name)
        Rails.cache.fetch("action_agent/code_sessions/health/#{name}", expires_in: HEALTH_TTL) do
          orchestrator.healthy?
        end
      rescue StandardError
        orchestrator.healthy?
      end

      def backend_supports?(session)
        CodeSessionOrchestrator.new(backend: session.backend).supports?(session.tool)
      rescue CodeSessionOrchestrator::UnsupportedBackendError
        false
      end

      def catalog_entry(entry, supported)
        available = supported.include?(entry.key)
        entry.as_json_summary.merge(
          supported: available,
          reason: available ? nil : "The #{CodeSessionOrchestrator.default_backend} backend cannot launch #{entry.name}"
        )
      end

      def github_configured?
        ActionAgent.github_token_for(current_owner).present?
      rescue StandardError
        false
      end

      def code_session_params
        @code_session_params ||= begin
          source = params[:code_session].presence || params
          source.permit(
            :agent_id, :evaluation_run_id, :tool, :backend, :repository, :branch,
            :github_access, :network_mode, :model, :task, :run
          )
        end
      end

      def requested_agent
        @requested_agent ||= owner_agents.find(code_session_params[:agent_id])
      end

      # The run whose findings seed the brief. Read through the agent so a
      # run id belonging to somebody else's agent is a 404 rather than a way
      # to read their evaluation results.
      def evaluation_run_for(agent)
        id = code_session_params[:evaluation_run_id]
        return nil if id.blank?

        EvaluationRun.joins(:evaluation).where(Evaluation.table_name => { agent_id: agent.id }).find(id)
      end

      def build_brief(agent, run, session: nil)
        CodeSessionBrief.new(
          agent: agent,
          tool: code_session_params[:tool].to_s,
          evaluation_run: run,
          backend: session ? CodeSessionOrchestrator.new(backend: session.backend) : orchestrator,
          owner: current_owner,
          network_mode: code_session_params[:network_mode].presence || "restricted",
          github_access: code_session_params[:github_access].presence || "none",
          repository: code_session_params[:repository],
          task: session ? nil : code_session_params[:task]
        )
      end

      def run_requested?
        value = code_session_params[:run]
        value.to_s != "false" && value.present?
      end

      # The refusal AgentsController gives an observed agent: it was
      # discovered from telemetry and has no code of ours to improve.
      def require_executable_agent!
        return unless requested_agent.observed?

        render json: {
          error: "Observed agents are read-only — duplicate this agent to create an executable copy"
        }, status: :unprocessable_entity
      end

      # Sandboxes cost real compute for as long as they live, so an owner
      # can only hold a few at a time.
      def capacity_denial
        limit = ActionAgent.code_session_limits[:max_sessions_per_owner].to_i
        return nil unless limit.positive?
        return nil if owned(CodeSession).active.count < limit

        "You already have #{limit} active code sessions. Stop one before starting another."
      end

      def assign_owner(session, association, record)
        return if record.nil?
        return unless session.respond_to?(:"#{association}=")
        return unless CodeSession.column_names.include?("#{association}_id")

        session.public_send(:"#{association}=", record)
      end

      def actor_label
        current_user.try(:email_address) || current_user.try(:email) || "the dashboard"
      end
    end
  end
end
