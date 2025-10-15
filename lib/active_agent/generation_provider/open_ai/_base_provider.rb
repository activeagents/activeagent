require_relative "../_base_provider"

require_gem!(:openai, __FILE__)

require_relative "options"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      class BaseProvider < ActiveAgent::GenerationProvider::BaseProvider
        include StreamProcessing
        include MessageFormatting
        include ToolManagement

        # @return [OpenAI::Client]
        def client
          ::OpenAI::Client.new(options.client_options)
        end

        def generate(prompt_context)
          with_error_handling do
            generate_prompt(prompt_context)
          end
        end

        # @return [String] Name of service, e.g., Anthropic
        def service_name = "OpenAI"

        protected

        # @return [Class] The Options class for the specific provider, e.g., Anthropic::Options
        def options_type = OpenAI::Options

        def handle_message(prompt_context, message_json)
          ActiveAgent::ActionPrompt::Message.new(
            generate_id:       message_json["id"],
            content:           message_json["content"].first["text"],
            role:              message_json["role"].intern,
            action_requested:  message_json["finish_reason"] == "tool_calls",
            raw_actions:       message_json["tool_calls"] || [],
            requested_actions: handle_actions(message_json["tool_calls"]),
            content_type:      prompt_context[:output_schema].present? ? "application/json" : "text/plain"
          )
        end
      end
    end
  end
end
