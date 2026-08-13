# frozen_string_literal: true

module ActionAgent
  module Api
    # Read API for the tool inventory, backing the dashboard Tools view.
    #
    # Nothing here is registered by hand: ToolDiscovery derives the
    # inventory from the tool roster each generation request offered, from
    # telemetry tool spans, and from solid_agent generation/message records,
    # then unions it with the tools each agent has enabled in the builder so
    # configured-but-unused tools are visible too.
    class ToolsController < BaseController
      before_action :require_owner!

      # Filter labels for the view's origin tabs, so the set of buckets is
      # defined server-side alongside the classification that produces them.
      ORIGIN_FILTERS = {
        "all" => "All tools",
        ToolDiscovery::ORIGIN_MCP => "MCP",
        ToolDiscovery::ORIGIN_BUILTIN => "Dashboard",
        ToolDiscovery::ORIGIN_AGENT => "Agent-defined"
      }.freeze

      # GET /api/tools
      def index
        inventory = discovery.inventory

        render json: inventory.merge(
          tools: filtered(inventory[:tools]),
          origins: ORIGIN_FILTERS
        )
      end

      private

      def discovery
        ToolDiscovery.new(traces: owned_traces, agents: owner_agents, hours: window_hours)
      end

      def filtered(tools)
        if ORIGIN_FILTERS.key?(params[:origin].to_s) && params[:origin] != "all"
          tools = tools.select { |tool| tool[:origin] == params[:origin] }
        end
        tools = tools.select { |tool| tool[:mcp_server] == params[:server] } if params[:server].present?

        if (query = params[:q].to_s.strip.downcase).present?
          tools = tools.select { |tool| tool[:name].downcase.include?(query) }
        end

        tools
      end

      def window_hours
        params.fetch(:hours, ToolDiscovery::DEFAULT_WINDOW_HOURS).to_i
      end
    end
  end
end
