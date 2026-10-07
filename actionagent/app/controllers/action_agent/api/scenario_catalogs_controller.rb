# frozen_string_literal: true

module ActionAgent
  module Api
    # Scenario catalogs: the YAML catalogs of evaluation scenarios an owner
    # keeps, imported from a document, an uploaded file or a connected
    # repository at a ref, exported as YAML, synced to Active Storage, and
    # run one set at a time against an agent or a project.
    #
    # Importing and running change evaluation scenarios, so both need the
    # :replace_scenarios permission, as replacing an evaluation's scenarios
    # does. A run executes the agent, so it is gated as POST
    # /api/evaluations/:id/run is: the execution switch and the owner's
    # execution quota.
    class ScenarioCatalogsController < BaseController
      before_action :require_owner!
      before_action :set_catalog, only: [ :show, :update, :destroy, :export, :sync, :run_set, :materialize_set ]
      before_action :require_execution_enabled!, :enforce_execution_quota!, only: [ :run_set ]

      rescue_from ScenarioCatalogImport::Invalid, ScenarioSet::NoAgent do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end

      # GET /api/scenario_catalogs
      def index
        catalogs = owned(ScenarioCatalog).ordered.includes(products: { sets: :scenarios }).to_a
        render json: {
          catalogs: catalogs.map { |catalog| ScenarioCatalogSerializer.summary(catalog) },
          storage_available: ScenarioCatalog.attachments_available?
        }
      end

      # GET /api/scenario_catalogs/:id
      def show
        render json: { catalog: ScenarioCatalogSerializer.full(@catalog) }
      end

      # POST /api/scenario_catalogs
      # One of:
      #   document:   the catalog's YAML text
      #   file:       an uploaded .yml
      #   repository: owner/name of a connected repository, with ref (its
      #               default branch when omitted) and path (a directory of
      #               .yml files, .activeagents/evals by default, or one file)
      # Answers the imported catalogs. A repository the GitHub connection
      # has not selected needs :manage_github, as reading one for a project
      # does.
      def create
        return unless authorize_action!(:replace_scenarios, ScenarioCatalog.new)

        catalogs =
          if params[:repository].present?
            import_from_repository or return
          else
            [ import_document(document_param, name: params[:name].presence, source_path: params[:source_path].presence) ]
          end

        render json: { catalogs: catalogs.map { |catalog| ScenarioCatalogSerializer.full(catalog) } }, status: :created
      end

      # PATCH /api/scenario_catalogs/:id
      # With a document or file, re-imports it into this catalog (its
      # products, sets and scenarios become the document's); otherwise
      # renames or describes the catalog.
      def update
        return unless authorize_action!(:replace_scenarios, @catalog)

        if params[:document].present? || params[:file].present?
          import_document(document_param, catalog: @catalog, source_path: params[:source_path].presence || @catalog.source_path)
        else
          attributes = params.require(:catalog).permit(:name, :description)
          @catalog.update!(attributes)
          @catalog.refresh_document!
          @catalog.sync_to_storage!
        end

        render json: { catalog: ScenarioCatalogSerializer.full(@catalog.reload) }
      end

      # DELETE /api/scenario_catalogs/:id
      # The evaluations the catalog's sets became stay, with their runs.
      def destroy
        return unless authorize_action!(:replace_scenarios, @catalog)

        @catalog.destroy!
        head :no_content
      end

      # GET /api/scenario_catalogs/:id/export
      # The canonical YAML, as a download.
      def export
        send_data @catalog.export_yaml, filename: "#{@catalog.key.tr('/', '-')}.yml", type: "application/x-yaml", disposition: "attachment"
      end

      # POST /api/scenario_catalogs/:id/sync
      # direction=push (the default) writes the document to Active Storage;
      # direction=pull replaces the records with the stored document.
      def sync
        return unless authorize_action!(:replace_scenarios, @catalog)
        unless ScenarioCatalog.attachments_available?
          return render json: { error: "Active Storage is off for this dashboard (ActionAgent.active_storage)", code: "no_storage" },
            status: :unprocessable_entity
        end

        if params[:direction].to_s == "pull"
          @catalog.restore_from_storage!
        else
          @catalog.sync_to_storage!
        end

        render json: { catalog: ScenarioCatalogSerializer.full(@catalog.reload) }
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message, code: "no_document" }, status: :not_found
      end

      # POST /api/scenario_catalogs/:id/sets/:set_id/materialize
      # Creates or refreshes the evaluation the set runs as, on agent_id or
      # the product's target, without running it.
      def materialize_set
        return unless authorize_action!(:replace_scenarios, @catalog)

        set = find_set
        evaluation = set.materialize!(agent: requested_agent)
        render json: { set: set.reload.summary, evaluation: EvaluationSerializer.summary(evaluation) }
      end

      # POST /api/scenario_catalogs/:id/sets/:set_id/run
      # Runs the set against agent_id, against project_id (the project's
      # sandbox is booted if it is not running, and every replay reaches it
      # and its browser), or against the product's own target. models and
      # keys narrow the run as they do for an evaluation.
      def run_set
        return unless authorize_action!(:replace_scenarios, @catalog)

        set = find_set
        project = owned(Project).find(params[:project_id]) if params[:project_id].present?
        agent = requested_agent || project&.target_agent || set.product.target_agent(owner_agents)
        if agent.nil?
          return render json: { error: "Choose the agent to run against", code: "no_target" }, status: :unprocessable_entity
        end
        if agent.observed?
          return render json: { error: "Observed agents are read-only — duplicate this agent to create an executable copy" },
            status: :unprocessable_entity
        end
        if project
          boot_project_sandbox!(project) or return
        end

        selection = evaluation_run_selection(params).except(:scenario_ids, :group)
        run = set.run!(agent: agent, project: project, mount_url: "#{request.base_url}#{request.script_name}", **selection)
        render json: {
          set: set.reload.summary,
          evaluation: EvaluationSerializer.summary(run.evaluation),
          run: { id: run.id, status: run.status, evaluation_id: run.evaluation_id }
        }, status: :accepted
      end

      private

      include EvaluationRunStarting

      def set_catalog
        @catalog = owned(ScenarioCatalog).find(params[:id])
      end

      def find_set
        ScenarioSet.where(scenario_product_id: @catalog.products.select(:id)).find(params[:set_id])
      end

      def requested_agent
        params[:agent_id].present? ? owner_agents.find(params[:agent_id]) : nil
      end

      # The YAML given as text or as an uploaded file.
      def document_param
        file = params[:file]
        return file.read if file.respond_to?(:read)

        params[:document].to_s
      end

      def import_document(document, catalog: nil, name: nil, source_path: nil)
        ScenarioCatalogImport.new(
          owner: current_owner, document: document, catalog: catalog, name: name,
          source_kind: "upload", source_path: source_path,
          agents: owner_agents, projects: owned(Project)
        ).call
      end

      # Imports from the connected repository params name. nil, with the
      # refusal rendered, when there is no connection or the repository is
      # not one the caller may read.
      def import_from_repository
        connection = GithubConnection.for_owner(current_owner).first
        if connection.nil?
          render json: { error: "Connect GitHub in Settings first", code: "no_github_connection" }, status: :unprocessable_entity
          return nil
        end

        repository = params[:repository].to_s
        if connection.repository(repository).nil? && !ActionAgent.permitted?(current_user, :manage_github, connection)
          permission_denied(:manage_github)
          return nil
        end

        ScenarioCatalogRepositoryImport.new(
          owner: current_owner, connection: connection, repository: repository,
          ref: params[:ref].presence, path: params[:path].presence,
          agents: owner_agents, projects: owned(Project)
        ).call
      end

      # Boots the project's sandbox when none is running, as the project's
      # own run does. nil, with the refusal rendered, when it cannot.
      def boot_project_sandbox!(project)
        before = project.current_sandbox_session_id
        sandbox = project.ensure_sandbox!(confirm: ActiveModel::Type::Boolean.new.cast(params[:confirm]) == true, confirmed_by: current_user)
        record_execution_usage if sandbox.id != before
        sandbox
      rescue ActiveRecord::RecordInvalid => e
        raise unless e.record.is_a?(SandboxSession)

        render json: { error: "The project's sandbox could not start: #{e.record.errors.full_messages.to_sentence}" },
          status: :unprocessable_entity
        nil
      end
    end
  end
end
