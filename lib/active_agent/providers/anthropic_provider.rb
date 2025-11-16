# lib/active_agent/providers/anthropic_provider.rb

require_relative "_base_provider"

require_gem!(:anthropic, __FILE__)

require_relative "anthropic/_types"
require_relative "anthropic/transforms"

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

      # Removes forced tool choice after first use to prevent endless looping.
      #
      # Clears tool_choice when the specified tool has already been called in the
      # conversation, preventing the model from being forced to call it repeatedly.
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
        return unless request.tool_choice.respond_to?(:type)

        functions_used = message_stack.pluck(:content).flatten.select { _1[:type] == "tool_use" }.pluck(:name)

        # tool_choice is always a gem model object (ToolChoiceAny, ToolChoiceTool, ToolChoiceAuto)
        tool_choice_type = request.tool_choice.type
        tool_choice_name = request.tool_choice.respond_to?(:name) ? request.tool_choice.name : nil

        if (tool_choice_type == :any && functions_used.any?) ||
          (tool_choice_type == :tool && tool_choice_name && functions_used.include?(tool_choice_name))

          instrument("tool_choice_removed.provider.active_agent")
          request.tool_choice = nil
        end
      end

      # @api private
      def prepare_prompt_request_response_format
        return unless request.response_format&.dig(:type) == "json_object"

        self.message_stack.push({
          role:    "assistant",
          content: "Here is the JSON requested:\n{"
        })
      end

      # @see BaseProvider#api_prompt_executer
      # @return [Anthropic::Messages]
      def api_prompt_executer
        client.messages
      end

      # Processes streaming chunks and builds message incrementally in message_stack.
      #
      # Handles chunk types: message_start, content_block_start, content_block_delta,
      # content_block_stop, message_delta, message_stop. Manages text deltas,
      # tool use inputs, and Claude's thinking/signature blocks.
      #
      # @see BaseProvider#process_stream_chunk
      # @param api_response_chunk [Anthropic::StreamEvent]
      # @return [void]
      def process_stream_chunk(api_response_chunk)
        chunk_type = api_response_chunk.type.to_sym

        instrument("stream_chunk_processing.provider.active_agent", chunk_type:)

        broadcast_stream_open

        case chunk_type
        # Message Created
        when :message_start
          api_message = Anthropic::Transforms.gem_to_hash(api_response_chunk.message)
          self.message_stack.push(api_message)
          broadcast_stream_update(message_stack.last)

        # -> Content Block Create
        when :content_block_start
          api_content = Anthropic::Transforms.gem_to_hash(api_response_chunk.content_block)
          self.message_stack.last[:content].push(api_content)
          broadcast_stream_update(message_stack.last, api_content[:text])

        # -> -> Content Block Append
        when :content_block_delta
          index     = api_response_chunk.index
          content   = self.message_stack.last[:content][index]
          api_delta = api_response_chunk.delta

          case api_delta.type.to_sym
          # -> -> -> Content Text Append
          when :text_delta
            content[:text] += api_delta.text
            broadcast_stream_update(message_stack.last, api_delta.text)

          # -> -> -> Content Function Call Append
          when :input_json_delta
            # No-Op; Wait for Function call to be complete
          when :thinking_delta, :signature_delta
            # TODO: Add with thinking rendering support
          else
            raise "Unexpected delta type: #{api_delta.type}"
          end
        # -> Content Block Completed [Full Block]
        when :content_block_stop
          index       = api_response_chunk.index
          api_content = Anthropic::Transforms.gem_to_hash(api_response_chunk.content_block)
          self.message_stack.last[:content][index] = api_content

        # Message Delta
        when :message_delta
          delta = Anthropic::Transforms.gem_to_hash(api_response_chunk.delta)
          self.message_stack.last.merge!(delta)

        # Message Completed [Full Message]
        when :message_stop
          api_message = Anthropic::Transforms.gem_to_hash(api_response_chunk.message)

          # Handle _json_buf (gem >= 1.14.0)
          api_message[:content]&.each do |content_block|
            content_block.delete(:_json_buf) if content_block[:type] == "tool_use"
          end

          self.message_stack[-1] = api_message

          # Once we are finished, close out and run tooling callbacks (Recursive)
          process_prompt_finished if message_stack.last[:stop_reason]
        when :ping
          # No-Op Keep Awake
        when :overloaded_error
          # TODO: https://docs.claude.com/en/docs/build-with-claude/streaming#error-events
        else
          # No-Op: Looks like internal tracking from gem wrapper
          return if api_response_chunk.respond_to?(:snapshot)
          raise "Unexpected chunk type: #{api_response_chunk.type}"
        end
      end

      # Executes tool calls and appends user message with results to message_stack.
      #
      # @param api_function_calls [Array<Hash>] with :name, :input, and :id keys
      # @return [void]
      def process_function_calls(api_function_calls)
        content = api_function_calls.map do |api_function_call|
          process_tool_call_function(api_function_call)
        end

        api_message = ::Anthropic::Models::MessageParam.new(role: "user", content:)
        message     = Anthropic::Transforms.gem_to_hash(api_message)

        message_stack.push(message)
      end

      # Executes a single tool call via callback.
      #
      # @param api_function_call [Hash] with :name, :input, and :id keys
      # @return [Anthropic::Models::ToolResultBlockParam]
      def process_tool_call_function(api_function_call)
        instrument("tool_execution.provider.active_agent", tool_name: api_function_call[:name])

        results = tools_function.call(
          api_function_call[:name], **api_function_call[:input]
        )

        ::Anthropic::Models::ToolResultBlockParam.new(
          type:        "tool_result",
          tool_use_id: api_function_call[:id],
          content:     results.to_json,
        )
      end

      # Converts API response message to hash for message_stack.
      #
      # Handles JSON response format simulation by prepending `{` to the response
      # content after removing the assistant lead-in message.
      #
      # @see BaseProvider#process_prompt_finished_extract_messages
      # @param api_response [Anthropic::Models::Message]
      # @return [Array<Hash>, nil]
      def process_prompt_finished_extract_messages(api_response)
        return unless api_response

        # Handle JSON response format simulation
        if request.response_format&.dig(:type) == "json_object"
          request.pop_message!
          api_response.content[0].text = "{#{api_response.content[0].text}"
        end

        message = Anthropic::Transforms.gem_to_hash(api_response)

        [ message ]
      end

      # Extracts tool_use blocks from message_stack and parses JSON inputs.
      #
      # Handles JSON buffer parsing for gem versions and string inputs for gem >= 1.14.0.
      #
      # @see BaseProvider#process_prompt_finished_extract_function_calls
      # @return [Array<Hash>] with :name, :input, and :id keys
      def process_prompt_finished_extract_function_calls
        message_stack.pluck(:content).flatten.select { _1 in { type: "tool_use" } }.map do |api_function_call|
          json_buf = api_function_call.delete(:json_buf)
          api_function_call[:input] = JSON.parse(json_buf, symbolize_names: true) if json_buf

          # Handle case where :input is still a JSON string (gem >= 1.14.0)
          if api_function_call[:input].is_a?(String)
            api_function_call[:input] = JSON.parse(api_function_call[:input], symbolize_names: true)
          end

          api_function_call
        end
      end
    end
  end
end
