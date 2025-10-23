# lib/active_agent/providers/anthropic_provider.rb

require_relative "_base_provider"

require_gem!(:anthropic, __FILE__)

require_relative "anthropic/_types"

module ActiveAgent
  module Providers
    # Provider implementation for Anthropic's Claude models.
    #
    # Handles communication with Anthropic's API, including message creation,
    # streaming responses, and tool/function calling. Supports Claude's unique
    # features like thinking mode and content blocks.
    #
    # @see BaseProvider
    class AnthropicProvider < BaseProvider
      # Returns the Anthropic API client.
      #
      # @todo Add support for Anthropic::BedrockClient and Anthropic::VertexClient
      # @return [Anthropic::Client] The configured Anthropic client
      def client
        ::Anthropic::Client.new(**options.serialize)
      end

      protected

      # Prepares the request and handles tool choice cleanup.
      #
      # When a tool choice is forced to be used, we need to remove it from the next
      # request to prevent endless looping.
      #
      # @return [Request] The prepared request object
      def prepare_prompt_request
        if request.tool_choice
          functions_used = message_stack.pluck(:content).flatten.select { it[:type] == "tool_use" }.pluck(:name)

          if (request.tool_choice.type == "any" && functions_used.any?) ||
            (request.tool_choice.type == "tool" && functions_used.include?(request.tool_choice.name))

            instrument("tool_choice_removed.provider.active_agent")
            request.tool_choice = nil
          end
        end

        super
      end

      # Executes the prompt request via Anthropic's API.
      #
      # @param parameters [Hash] The API request parameters
      # @return [Object, nil] The API response object for non-streaming requests, nil for streaming
      # @raise [Exception] Re-raises the underlying connection error for APIConnectionError
      def api_prompt_execute(parameters)
        unless parameters[:stream]
          instrument("api_request.provider.active_agent", model: parameters[:model], streaming: false)
          client.messages.create(**parameters)
        else
          instrument("api_request.provider.active_agent", model: parameters[:model], streaming: true)
          client.messages.stream(**parameters.except(:stream)).each(&parameters[:stream])
          nil
        end
      rescue ::Anthropic::Error => exception
        raise exception.cause if exception.cause
        raise exception
      end

      # Processes streaming response chunks from Anthropic's API.
      #
      # Handles various chunk types including message creation, content blocks,
      # deltas for text and tool use, and completion events. Manages the message
      # stack and broadcasts streaming updates.
      #
      # @param api_response_chunk [Object] The streaming response chunk
      # @return [void]
      def process_stream_chunk(api_response_chunk)
        api_response_chunk = api_response_chunk.as_json.deep_symbolize_keys
        chunk_type = api_response_chunk[:type].to_sym

        instrument("stream_chunk_processing.provider.active_agent", chunk_type:)

        broadcast_stream_open

        case chunk_type
        # Message Created
        when :message_start
          api_message = api_response_chunk.fetch(:message)
          self.message_stack.push(api_message)
          broadcast_stream_update(message_stack.last)

        # -> Content Block Create
        when :content_block_start
          api_content = api_response_chunk.fetch(:content_block)
          self.message_stack.last[:content].push(api_content)
          broadcast_stream_update(message_stack.last, api_content[:text])

        # -> -> Content Block Append
        when :content_block_delta
          index     = api_response_chunk.fetch(:index)
          content   = self.message_stack.last[:content][index]
          api_delta = api_response_chunk.fetch(:delta)

          case (delta_type = api_delta[:type].to_sym)
          # -> -> -> Content Text Append
          when :text_delta
            content[:text] += api_delta[:text]
            broadcast_stream_update(message_stack.last, api_delta[:text])

          # -> -> -> Content Function Call Append
          when :input_json_delta
            # No-Op; Wait for Function call to be complete
          when :thinking_delta, :signature_delta
            # TODO: Add with thinking rendering support
          else
            fail "Unexpected Delta Type #{delta_type}"
          end
        # -> Content Block Completed [Full Block]
        when :content_block_stop
          index       = api_response_chunk.fetch(:index)
          api_content = api_response_chunk.fetch(:content_block)
          self.message_stack.last[:content][index] = api_content

        # Message Delta
        when :message_delta
          self.message_stack.last.merge!(api_response_chunk.fetch(:delta))

        # Message Completed [Full Message]
        when :message_stop
          self.message_stack[-1] = api_response_chunk.fetch(:message)

          # Once we are finished, close out and run tooling callbacks (Recursive)
          process_prompt_finished if message_stack.last[:stop_reason]
        when :ping
          # No-Op Keep Awake
        when :overloaded_error
          # TODO: https://docs.claude.com/en/docs/build-with-claude/streaming#error-events
        else
          # No-Op: Looks like internal tracking from gem wrapper
          return if api_response_chunk.key?(:snapshot)
          fail "Unexpected Chunk Type: #{api_response_chunk[:type]}"
        end
      end

      # Processes function/tool calls from the API response.
      #
      # Executes each tool call and creates a user message with the results
      # for the next iteration of the conversation.
      #
      # @param api_function_calls [Array<Hash>] Array of function call objects
      # @return [void]
      def process_function_calls(api_function_calls)
        content = api_function_calls.map do |api_function_call|
          process_tool_call_function(api_function_call)
        end

        message = Anthropic::Requests::Messages::User.new(content:)

        message_stack.push(message.serialize)
      end

      # Executes a single tool call and returns the result.
      #
      # @param api_function_call [Hash] The function call object with name, input, and id
      # @return [Anthropic::Requests::Content::ToolResult] The tool result object
      def process_tool_call_function(api_function_call)
        instrument("tool_execution.provider.active_agent", tool_name: api_function_call[:name])

        results = tools_function.call(
          api_function_call[:name], **api_function_call[:input]
        )

        Anthropic::Requests::Content::ToolResult.new(
          tool_use_id: api_function_call[:id],
          content:     results.to_json,
        )
      end

      # Extracts messages from the completed API response.
      #
      # @param api_response [Object] The completed API response
      # @return [Array<Hash>, nil] Array containing the symbolized response hash or nil
      def process_prompt_finished_extract_messages(api_response)
        return unless api_response

        [ api_response.as_json.deep_symbolize_keys ]
      end

      # Extracts function calls from the message stack.
      #
      # Looks for tool_use content blocks in the message stack and processes
      # any JSON buffers into proper input parameters.
      #
      # @return [Array<Hash>] Array of function call hashes with name, input, and id
      def process_prompt_finished_extract_function_calls
        message_stack.pluck(:content).flatten.select { it in { type: "tool_use" } }.map do |api_function_call|
          json_buf = api_function_call.delete(:json_buf)
          api_function_call[:input] = JSON.parse(json_buf, symbolize_names: true) if json_buf
          api_function_call
        end
      end
    end
  end
end
