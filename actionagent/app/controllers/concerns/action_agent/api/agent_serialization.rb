# frozen_string_literal: true

module ActionAgent
  module Api
    # The agent JSON the dashboard reads, shared by every endpoint that hands
    # an agent to the React app.
    #
    # Two shapes: the summary the list renders, and the detail (instructions,
    # tools, mcp_servers, model_config, ...) the editor initializes from. Any
    # endpoint that returns an agent the client may go on to *edit* must
    # render the detail shape: AgentEditor seeds its form from whatever it is
    # given, and a summary seeds it with empty instructions/tools/config,
    # which the first Save then persists over the real record.
    module AgentSerialization
      extend ActiveSupport::Concern

      private

      def agent_json(agent, include_details: false)
        json = {
          id: agent.id,
          name: agent.name,
          slug: agent.slug,
          description: agent.description,
          provider: agent.provider,
          model: agent.model,
          status: agent.status,
          preset_type: agent.preset_type,
          appearance: agent.appearance,
          version_count: agent.version_count,
          created_at: agent.created_at,
          updated_at: agent.updated_at
        }

        if include_details
          json.merge!(
            instructions: agent.instructions,
            action_prompts: agent.action_prompts,
            instruction_sets: agent.instruction_sets,
            tools: agent.tools,
            mcp_servers: agent.mcp_servers,
            model_config: agent.model_config,
            response_format: agent.response_format,
            agent_class_name: agent.agent_class_name,
            telemetry_agent_class: agent.telemetry_agent_class
          )
        end

        json
      end
    end
  end
end
