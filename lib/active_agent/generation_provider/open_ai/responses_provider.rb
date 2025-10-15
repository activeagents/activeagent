require_relative "_base_provider"
require_relative "responses/request"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      # @see https://platform.openai.com/docs/api-reference/responses
      class ResponsesProvider < BaseProvider
        protected

        def generate_prompt(context)
          request = Responses::Request.new # Default Options
          request.merge!(options.to_hc)    # Agent Options
          request.merge!(context)          # Action Options

          api_response = client.responses.create(parameters: request.to_hc)
          response(context, api_response, request.to_hc)
        end

        # @param raw_response [...] OpenAI Client's Responses API Create result
        # @param raw_request  [Hash] The parameters sent in the request
        def response(context, raw_response, raw_request)
          message_json = raw_response["output"].find { |output_item| output_item["type"] == "message" }
          message_json["id"] = raw_response.dig("id") if message_json["id"].blank?

          @response = ActiveAgent::GenerationProvider::Response.new(
            prompt: context,
            message: handle_message(context, message_json),
            raw_response:,
            raw_request:
          )
        end

        def handle_message(context, message_json)
          ActiveAgent::ActionPrompt::Message.new(
            generate_id:      message_json["id"],
            content:          message_json["content"].first["text"],
            role:             message_json["role"].intern,
            action_requested: message_json["finish_reason"] == "tool_calls",
            raw_actions:      message_json["tool_calls"] || [],
            content_type:     context[:output_schema].present? ? "application/json" : "text/plain"
          )
        end
      end
    end
  end
end
