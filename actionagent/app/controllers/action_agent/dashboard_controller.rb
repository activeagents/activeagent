# frozen_string_literal: true

module ActionAgent
  # Serves the React dashboard.
  #
  # Every path under the mount renders this one action; routing below it
  # happens in the browser. Initial state is handed over as a JSON data
  # attribute rather than through Inertia, so the engine works in any host
  # app without adding a frontend framework to it.
  class DashboardController < ApplicationController
    # The React dashboard brings its own chrome, so it does not use the
    # server-rendered layout the traces views share.
    layout -> { ActionAgent.layout || "action_agent/react" }

    def index
      render "action_agent/dashboard/index", locals: { props: props }
    end

    private

    def props
      {
        user: current_user_props,
        account: current_account_props,
        initialAgents: serialize_agents(owner_agents.order(updated_at: :desc).limit(20)),
        meta: meta_props,
        mountPath: active_agent_dashboard_mount_path,
        # Billing is the host app's business; the dashboard renders no
        # subscription chrome unless it is told about one.
        subscription: nil
      }
    end

    def owner_agents
      ActionAgent.agents_for(current_owner)
    end

    def meta_props
      {
        activeagentVersion: ActiveAgent::VERSION,
        providers: Agent::PROVIDERS,
        presetTypes: Agent::PRESET_TYPES,
        instructionSets: Agent::INSTRUCTION_SETS,
        availableTools: Agent::AVAILABLE_TOOLS,
        executionEnabled: ActionAgent.execution_enabled?,
        multiTenant: ActionAgent.multi_tenant?,
        upgradeUrl: ActionAgent.upgrade_url
      }
    end

    def serialize_agents(agents)
      agents = agents.to_a
      scorecards = AgentScorecard.for_agents(agents)

      agents.map do |agent|
        {
          id: agent.id,
          name: agent.name,
          slug: agent.slug,
          description: agent.description,
          provider: agent.provider,
          model: agent.model,
          status: agent.status,
          presetType: agent.preset_type,
          appearance: agent.appearance,
          versionCount: agent.version_count,
          createdAt: agent.created_at,
          updatedAt: agent.updated_at,
          stats: scorecards[agent.id]
        }
      end
    rescue ActiveRecord::StatementInvalid
      # Telemetry-only installs have the traces table but not the rest of
      # the dashboard schema; the app still boots and shows an empty list.
      []
    end

    def current_user_props
      return { name: "Guest" } unless current_user

      {
        id: current_user.id,
        name: current_user.try(:display_name) || current_user.try(:name) || current_user.try(:email_address),
        email: current_user.try(:email_address) || current_user.try(:email)
      }
    end

    def current_account_props
      return nil unless current_owner

      {
        id: current_owner.id,
        name: current_owner.try(:name),
        telemetry_api_key: current_owner.try(:telemetry_api_key)
      }
    end

    # Where the engine is mounted, so the React app can build API URLs
    # without assuming a path.
    def active_agent_dashboard_mount_path
      request.script_name.presence || "/"
    end
  end
end
