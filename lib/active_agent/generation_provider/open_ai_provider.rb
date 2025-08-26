begin
  gem "ruby-openai", ">= 8.1.0"
  require "openai"
rescue LoadError
  raise LoadError, "The 'ruby-openai' gem is required for OpenAIProvider. Please add it to your Gemfile and run `bundle install`."
end

require "active_agent/action_prompt/action"
require_relative "base"
require_relative "response"
require_relative "responses_adapter"
require_relative "stream_processing"
require_relative "message_formatting"
require_relative "tool_management"

module ActiveAgent
  module GenerationProvider
    class OpenAIProvider < Base
      include StreamProcessing
      include MessageFormatting
      include ToolManagement
      def initialize(config)
        super
        @host = config["host"] || nil
        @access_token ||= config["api_key"] || config["access_token"] || OpenAI.configuration.access_token || ENV["OPENAI_ACCESS_TOKEN"]
        @organization_id = config["organization_id"] || OpenAI.configuration.organization_id || ENV["OPENAI_ORGANIZATION_ID"]
        @admin_token = config["admin_token"] || OpenAI.configuration.admin_token || ENV["OPENAI_ADMIN_TOKEN"]
        @client = OpenAI::Client.new(
          access_token: @access_token,
          uri_base: @host,
          organization_id: @organization_id,
          admin_token: @admin_token,
          log_errors: Rails.env.development?
        )

        @model_name = config["model"] || "gpt-4o-mini"
      end

      def generate(prompt)
        @prompt = prompt

        with_error_handling do
          if @prompt.multimodal? || @prompt.content_type == "multipart/mixed"
            responses_prompt(parameters: responses_parameters)
          else
            chat_prompt(parameters: prompt_parameters)
          end
        end
      end

      def embed(prompt)
        @prompt = prompt

        with_error_handling do
          embeddings_prompt(parameters: embeddings_parameters)
        end
      end

      protected

      # Override from StreamProcessing module
      def process_stream_chunk(chunk, message, agent_stream)
        new_content = chunk.dig("choices", 0, "delta", "content")
        if new_content && !new_content.blank?
          message.generation_id = chunk.dig("id")
          message.content += new_content
          # Call agent_stream directly without the block to avoid double execution
          agent_stream&.call(message, new_content, false, prompt.action_name)
        elsif chunk.dig("choices", 0, "delta", "tool_calls") && chunk.dig("choices", 0, "delta", "role")
          message = handle_message(chunk.dig("choices", 0, "delta"))
          prompt.messages << message
          @response = ActiveAgent::GenerationProvider::Response.new(
            prompt:,
            message:,
            raw_response: chunk,
            raw_request: @streaming_request_params
          )
        end

        if chunk.dig("choices", 0, "finish_reason")
          finalize_stream(message, agent_stream)
        end
      end

      # Override from MessageFormatting module to handle OpenAI image format
      def format_image_content(message)
        [ {
          type: "image_url",
          image_url: { url: message.content }
        } ]
      end

      private

      # Override from ParameterBuilder to add web_search_options for Chat API
      def build_provider_parameters
        params = {}

        # Check if we're using a model that supports web_search_options in Chat API
        if chat_api_web_search_model? && @prompt.options[:web_search]
          params[:web_search_options] = build_web_search_options(@prompt.options[:web_search])
        end

        params
      end

      def chat_api_web_search_model?
        model = @prompt.options[:model] || @model_name
        [ "gpt-4o-search-preview", "gpt-4o-mini-search-preview" ].include?(model)
      end

      def build_web_search_options(web_search_config)
        options = {}

        if web_search_config.is_a?(Hash)
          options[:search_context_size] = web_search_config[:search_context_size] if web_search_config[:search_context_size]

          if web_search_config[:user_location]
            options[:user_location] = {
              type: "approximate",
              approximate: web_search_config[:user_location]
            }
          end
        end

        options
      end

      def chat_response(response, request_params = nil)
        return @response if prompt.options[:stream]
        message_json = response.dig("choices", 0, "message")
        message_json["id"] = response.dig("id") if message_json["id"].blank?
        message = handle_message(message_json)

        update_context(prompt: prompt, message: message, response: response)

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: prompt,
          message: message,
          raw_response: response,
          raw_request: request_params
        )
      end

      def responses_response(response, request_params = nil)
        message_json = response["output"].find { |output_item| output_item["type"] == "message" }
        message_json["id"] = response.dig("id") if message_json["id"].blank?

        message = ActiveAgent::ActionPrompt::Message.new(
          generate_id: message_json["id"],
          content: message_json["content"].first["text"],
          role: message_json["role"].intern,
          action_requested: message_json["finish_reason"] == "tool_calls",
          raw_actions: message_json["tool_calls"] || [],
          content_type: prompt.output_schema.present? ? "application/json" : "text/plain"
        )

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: prompt,
          message: message,
          raw_response: response,
          raw_request: request_params
        )
      end

      def handle_message(message_json)
        ActiveAgent::ActionPrompt::Message.new(
          generation_id: message_json["id"],
          content: message_json["content"],
          role: message_json["role"].intern,
          action_requested: message_json["finish_reason"] == "tool_calls",
          raw_actions: message_json["tool_calls"] || [],
          requested_actions: handle_actions(message_json["tool_calls"])
        )
      end

      # handle_actions is now provided by ToolManagement module

      def chat_prompt(parameters: prompt_parameters)
        if prompt.options[:stream] || config["stream"]
          parameters[:stream] = provider_stream
          @streaming_request_params = parameters
        end
        chat_response(@client.chat(parameters: parameters), parameters)
      end

      def responses_prompt(parameters: responses_parameters)
        # parameters[:stream] = provider_stream if prompt.options[:stream] || config["stream"]
        responses_response(@client.responses.create(parameters: parameters), parameters)
      end

      def responses_parameters(model: @prompt.options[:model] || @model_name, messages: @prompt.messages, temperature: @prompt.options[:temperature] || @config["temperature"] || 0.7, tools: @prompt.actions, structured_output: @prompt.output_schema)
        # Build tools array, combining action tools with built-in tools
        tools_array = build_tools_for_responses(tools)

        {
          model: model,
          input: ActiveAgent::GenerationProvider::ResponsesAdapter.new(@prompt).input,
          tools: tools_array.presence,
          text: structured_output
        }.compact
      end

      def build_tools_for_responses(action_tools)
        tools = []

        # Start with action tools (user-defined functions) if any
        tools.concat(action_tools) if action_tools.present?

        # Add built-in tools if specified in options[:tools]
        if @prompt.options[:tools].present?
          built_in_tools = @prompt.options[:tools]
          built_in_tools = [ built_in_tools ] unless built_in_tools.is_a?(Array)

          built_in_tools.each do |tool|
            next unless tool.is_a?(Hash)

            case tool[:type]
            when "web_search_preview", "web_search"
              web_search_tool = { type: "web_search_preview" }
              web_search_tool[:search_context_size] = tool[:search_context_size] if tool[:search_context_size]
              web_search_tool[:user_location] = tool[:user_location] if tool[:user_location]
              tools << web_search_tool

            when "image_generation"
              image_gen_tool = { type: "image_generation" }
              image_gen_tool[:size] = tool[:size] if tool[:size]
              image_gen_tool[:quality] = tool[:quality] if tool[:quality]
              image_gen_tool[:format] = tool[:format] if tool[:format]
              image_gen_tool[:compression] = tool[:compression] if tool[:compression]
              image_gen_tool[:background] = tool[:background] if tool[:background]
              image_gen_tool[:partial_images] = tool[:partial_images] if tool[:partial_images]
              tools << image_gen_tool

            when "mcp"
              mcp_tool = { type: "mcp" }
              mcp_tool[:server_label] = tool[:server_label] if tool[:server_label]
              mcp_tool[:server_description] = tool[:server_description] if tool[:server_description]
              mcp_tool[:server_url] = tool[:server_url] if tool[:server_url]
              mcp_tool[:connector_id] = tool[:connector_id] if tool[:connector_id]
              mcp_tool[:authorization] = tool[:authorization] if tool[:authorization]
              mcp_tool[:require_approval] = tool[:require_approval] if tool[:require_approval]
              mcp_tool[:allowed_tools] = tool[:allowed_tools] if tool[:allowed_tools]
              tools << mcp_tool
            end
          end
        end

        tools
      end

      def embeddings_parameters(input: prompt.message.content, model: "text-embedding-3-large")
        {
          model: model,
          input: input
        }
      end

      def embeddings_response(response, request_params = nil)
        message = ActiveAgent::ActionPrompt::Message.new(content: response.dig("data", 0, "embedding"), role: "assistant")

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: prompt,
          message: message,
          raw_response: response,
          raw_request: request_params
        )
      end

      def embeddings_prompt(parameters:)
        params = embeddings_parameters
        embeddings_response(@client.embeddings(parameters: params), params)
      end
    end
  end
end
