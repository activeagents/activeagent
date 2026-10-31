# frozen_string_literal: true

module ActionAgent
  module Api
    # The caller's own remote MCP servers (MCPServerConfig), managed from the
    # MCP Services page and enabled on agents as "custom:<id>".
    #
    # Every query goes through `owned`, so a caller reads, changes, tests and
    # deletes only their owner's configurations; another owner's id is a 404.
    # Header values are write-only: responses carry each header's name and a
    # masked value. On update, a header sent with a blank value keeps the
    # value stored under that name, and a header left out is removed; leaving
    # +headers+ out of the request keeps them all.
    #
    # Writes and tests ask permission_checker for :manage_credentials, since a
    # configuration holds credentials and decides what the owner's agents
    # call. Reading the list asks nothing.
    class MCPServerConfigsController < BaseController
      before_action :require_owner!
      before_action :set_config, only: %i[update destroy test]

      # GET /api/mcp_server_configs
      def index
        configs = owned(MCPServerConfig).order(:name, :id)

        render json: {
          mcp_server_configs: configs.map(&:as_api_json),
          allow_private_hosts: MCPHostGuard.allow_private?,
          can_manage: can_manage?
        }
      end

      # POST /api/mcp_server_configs
      def create
        config = owned(MCPServerConfig).new
        assign_attributes(config)
        return unless authorize_action!(:manage_credentials, config)

        config.save!
        render json: { mcp_server_config: config.as_api_json }, status: :created
      end

      # PATCH /api/mcp_server_configs/:id
      def update
        return unless authorize_action!(:manage_credentials, @config)

        assign_attributes(@config)
        # A new URL has not been tested; what an earlier test found about the
        # old one no longer describes it.
        reset_test_result(@config) if @config.url_changed?
        @config.save!
        render json: { mcp_server_config: @config.as_api_json }
      end

      # DELETE /api/mcp_server_configs/:id
      #
      # Agents that enable the configuration keep naming its key, which then
      # resolves to nothing: the Tools tab lists it as unknown so it can be
      # switched off.
      def destroy
        return unless authorize_action!(:manage_credentials, @config)

        @config.destroy!
        head :no_content
      end

      # POST /api/mcp_server_configs/:id/test
      #
      # Runs tools/list against the saved configuration and records the
      # outcome, the discovered tool names included. Answers 200 either way:
      # a server that does not answer is a result to show, not a failed
      # request.
      def test
        return unless authorize_action!(:manage_credentials, @config)

        result = @config.test_connection!
        render json: result.merge(mcp_server_config: @config.as_api_json)
      end

      private

      def set_config
        @config = owned(MCPServerConfig).find(params[:id])
      end

      def can_manage?
        ActionAgent.permitted?(current_user, :manage_credentials, owned(MCPServerConfig).new)
      end

      def assign_attributes(config)
        attributes = params.require(:mcp_server_config).permit(:name, :description, :url, :enabled)
        config.assign_attributes(attributes)
        config.assign_headers(header_params) if params[:mcp_server_config].key?(:headers)
      end

      # The submitted headers as { name, value } pairs. Accepts a list, or a
      # Hash of name => value.
      def header_params
        submitted = params[:mcp_server_config][:headers]
        return [] if submitted.blank?

        if submitted.is_a?(Array)
          submitted.map { |header| header.respond_to?(:permit) ? header.permit(:name, :value).to_h : {} }
        else
          submitted.permit!.to_h.map { |name, value| { "name" => name, "value" => value } }
        end
      end

      def reset_test_result(config)
        config.assign_attributes(last_tested_at: nil, last_test_status: nil, last_test_error: nil, tool_names: [])
      end
    end
  end
end
