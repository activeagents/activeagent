# frozen_string_literal: true

module ActionAgent
  module Api
    # Read API for MCP services, plus sandbox provisioning for the servers
    # that can be started on demand. Backs the dashboard MCP Services view.
    #
    # The list is the union of three things: servers detected from telemetry
    # and solid_agent records (ToolDiscovery), servers an agent declares in
    # its configuration, and the default catalog (MCPCatalog). An install
    # therefore sees both what it is already using and what it could turn on.
    class McpServersController < BaseController
      before_action :require_owner!
      # Launching provisions a sandbox and runs a server in it, so it answers
      # to the same two gates as any other execution: the read-only kill
      # switch, and whatever limits the host app imposes.
      before_action :require_execution_enabled!, only: [ :launch ]
      before_action :enforce_execution_quota!, only: [ :launch ]
      before_action :set_catalog_entry, only: [ :show, :launch ]

      STATUS_LABELS = {
        "active" => "Called in this window",
        "configured" => "Declared by an agent, no traffic yet",
        "available" => "Available to connect",
        "idle" => "Seen previously, no traffic in this window"
      }.freeze

      # GET /api/mcp_servers
      def index
        finder = discovery
        tools = finder.detected_tools
        servers = finder.servers(tools)

        render json: {
          servers: servers,
          catalog: MCPCatalog.all,
          summary: summary_for(servers),
          sandboxes: active_sandboxes,
          window_hours: finder.window_hours,
          statuses: STATUS_LABELS
        }
      end

      # GET /api/mcp_servers/:id
      #
      # One server with the tools detected for it, so the view can expand a
      # row without refetching the whole inventory.
      def show
        finder = discovery
        tools = finder.detected_tools
        server = finder.servers(tools).find { |row| row[:key] == params[:id] }

        render json: {
          server: server || @catalog_entry,
          tools: tools.select { |tool| tool[:mcp_server] == params[:id] }
        }
      end

      # POST /api/mcp_servers/:id/launch
      #
      # Starts the server inside a sandbox session. Only catalog entries
      # marked +sandbox: true+ are launchable — the rest need credentials
      # the dashboard has nowhere safe to source, so they are listed but not
      # startable.
      def launch
        unless @catalog_entry[:sandbox]
          return render json: {
            error: "#{@catalog_entry[:name]} can't be started from the dashboard",
            reason: launch_blocked_reason(@catalog_entry)
          }, status: :unprocessable_entity
        end

        sandbox = SandboxSession.new(
          sandbox_type: @catalog_entry[:sandbox_type] || "terminal",
          mcp_servers: [ @catalog_entry[:key] ]
        )
        # A sandbox belongs to whoever opened it, which is how
        # SandboxesController assigns them too — not to whatever
        # `current_owner` resolves to, since that is the account in a
        # multi-tenant install and this model prefers :user. Both are set
        # when the host app has them; a single-user install declares neither
        # association, so both are skipped.
        # respond_to? alone isn't enough: the association is declared from
        # configuration, but a host app's pre-existing table may not carry
        # the column behind it.
        assign_owner(sandbox, :user, current_user)
        assign_owner(sandbox, :account, current_account)

        if sandbox.save
          sandbox.provision!
          sandbox.reload
          record_execution_usage
          render json: { sandbox: sandbox.summary, server: @catalog_entry }, status: :created
        else
          render json: { error: sandbox.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def discovery
        ToolDiscovery.new(traces: owned_traces, agents: owner_agents, hours: window_hours)
      end

      def assign_owner(sandbox, association, record)
        return if record.nil?
        return unless sandbox.respond_to?(:"#{association}=")
        return unless sandbox.has_attribute?(:"#{association}_id")

        sandbox.public_send(:"#{association}=", record)
      end

      def set_catalog_entry
        @catalog_entry = MCPCatalog.find(params[:id])
        render json: { error: "Unknown MCP server: #{params[:id]}" }, status: :not_found if @catalog_entry.nil?
      end

      def launch_blocked_reason(entry)
        if entry[:requires_credentials].any?
          "Needs #{entry[:requires_credentials].to_sentence}. Configure it on an agent instead."
        else
          "This server runs outside the sandbox environment."
        end
      end

      def summary_for(servers)
        {
          total: servers.size,
          active: servers.count { |server| server[:status] == "active" },
          configured: servers.count { |server| server[:status] == "configured" },
          available: servers.count { |server| server[:status] == "available" },
          launchable: servers.count { |server| server[:launchable] },
          # Servers seen in traffic that the catalog doesn't describe — worth
          # surfacing, since they're the ones nobody documented.
          unknown: servers.count { |server| !server[:known] },
          total_calls: servers.sum { |server| server[:calls] }
        }
      end

      # Running sandboxes started with an MCP server, so the view can show
      # "running" beside the launch button instead of starting a second copy.
      def active_sandboxes
        owned(SandboxSession)
          .active
          .where(SandboxSession.json_array_not_empty_sql(:mcp_servers))
          .recent
          .limit(20)
          .map { |sandbox| sandbox.summary.merge(mcp_servers: Array(sandbox.mcp_servers)) }
      end

      def window_hours
        params.fetch(:hours, ToolDiscovery::DEFAULT_WINDOW_HOURS).to_i
      end
    end
  end
end
