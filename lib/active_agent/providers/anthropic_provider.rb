# lib/active_agent/providers/anthropic_provider.rb

require_relative "_base_provider"

require_gem!(:anthropic, __FILE__)

require_relative "anthropic/_types"

module ActiveAgent
  module Providers
    # Handles communication with Anthropic's Claude models.
    #
    # Supports message creation, streaming responses, tool calling, and Claude-specific
    # features like thinking mode and content blocks. Manages tool choice cleanup to
    # prevent endless looping when tools have been used in conversation history.
    #
    # @see BaseProvider
    class AnthropicProvider < BaseProvider
      # @todo Add support for Anthropic::BedrockClient and Anthropic::VertexClient
      # @return [Anthropic::Client]
      def client
        ::Anthropic::Client.new(**options.serialize)
      end

      protected

      # Prepares the request and handles tool choice cleanup.
      #
      # Removes forced tool choice from subsequent requests to prevent endless looping
      # when the tool has already been used in the conversation.
      #
      # @see BaseProvider#prepare_prompt_request
      # @return [Request]
      def prepare_prompt_request
        prepare_prompt_request_tools
        prepare_prompt_request_response_format

        super
      end

      # @api private
      def prepare_prompt_request_tools
        return unless request.tool_choice

        functions_used = message_stack.pluck(:content).flatten.select { _1[:type] == "tool_use" }.pluck(:name)

        if (request.tool_choice.type == "any" && functions_used.any?) ||
          (request.tool_choice.type == "tool" && functions_used.include?(request.tool_choice.name))

          instrument("tool_choice_removed.provider.active_agent")
          request.tool_choice = nil
        end
      end

      # @api private
      def prepare_prompt_request_response_format
        return unless request.response_format&.type == "json_object"

        self.message_stack.push({
          role:    "assistant",
          content: "Here is the JSON requested:\n{"
        })
      end

      def api_prompt_executer
        client.messages
      end

      # Processes streaming response chunks from Anthropic's API.
      #
      # Handles chunk types: message_start, content_block_start, content_block_delta,
      # content_block_stop, message_delta, message_stop. Manages text deltas,
      # tool use inputs, and Claude's thinking/signature blocks.
      #
      # @param api_response_chunk [Object]
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

      # Executes tool calls and creates user message with results.
      #
      # @param api_function_calls [Array<Hash>] with :name, :input, and :id keys
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
      # @param api_function_call [Hash] with :name, :input, and :id keys
      # @return [Anthropic::Requests::Content::ToolResult]
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

      # Extracts messages from completed API response.
      #
      # Handles JSON response format by merging the leading `{` prefix back into
      # the message content after removing the assistant lead-in message.
      #
      # @param api_response [Object]
      # @return [Array<Hash>, nil]
      def process_prompt_finished_extract_messages(api_response)
        return unless api_response

        message = api_response.as_json.deep_symbolize_keys

        if request.response_format&.type == "json_object"
          request.messages.pop # Remove the `Here is the JSON requested:\n{` lead in message
          message[:content][0][:text] = "{#{message[:content][0][:text]}" # Merge in `{` prefix
        end

        [ message ]
      end

      # Extracts function calls from message stack.
      #
      # Processes tool_use content blocks and converts JSON buffers into proper
      # input parameters for function execution.
      #
      # @return [Array<Hash>] with :name, :input, and :id keys
      def process_prompt_finished_extract_function_calls
        message_stack.pluck(:content).flatten.select { _1 in { type: "tool_use" } }.map do |api_function_call|
          json_buf = api_function_call.delete(:json_buf)
          api_function_call[:input] = JSON.parse(json_buf, symbolize_names: true) if json_buf
          api_function_call
        end
      end
    end
  end
end
