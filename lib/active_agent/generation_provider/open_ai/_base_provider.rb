require_relative "../_base_provider"

require_gem!(:openai, __FILE__)

require_relative "options"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      class BaseProvider < ActiveAgent::GenerationProvider::BaseProvider
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

        def parse_response_message(resolver, message_json)
          ActiveAgent::ActionPrompt::Message.new(
            generate_id:       message_json["id"],
            content:           message_json["content"].first["text"],
            role:              message_json["role"].intern,
            action_requested:  message_json["finish_reason"] == "tool_calls",
            raw_actions:       message_json["tool_calls"] || [],
            requested_actions: handle_actions(message_json["tool_calls"]),
            content_type:      resolver.context[:output_schema].present? ? "application/json" : "text/plain"
          )
        end

        # def provider_stream(resolver)
        #   message = ActiveAgent::ActionPrompt::Message.new(content: "", role: :assistant)

        #   proc do |chunk|
        #     stream_process(resolver, message, chunk)
        #   end
        # end

        # def stream_process(resolver, message, chunk)
        #   resolver.stream_callback.call(message, chunk, false)
        # end

        # def stream_finalize(resolver, message)
        #   resolver.stream_callback.call(message, nil, true)
        # end
      end
    end
  end
end
