# lib/active_agent/providers/anthropic_provider.rb

require_relative "_base_provider"

require_gem!(:anthropic, __FILE__)

require_relative "anthropic/options"
require_relative "anthropic/request"

module ActiveAgent
  module Providers
    class AnthropicProvider < BaseProvider
      # TODO: Anthropic::BedrockClient.new
      # TODO: Anthropic::VertexClient.new
      #
      # @return [Anthropic::Client]
      def client
        ::Anthropic::Client.new(**options.to_hc)
      end

      protected

      # When a tool choice is forced to be used, we need to remove it from the next
      # request to prevent endless looping.
      def prepare_request_iteration
        if request.tool_choice
          functions_used = message_stack.pluck(:content).flatten.select { it[:type] == "tool_use" }.pluck(:name)

          if (request.tool_choice.type == "any" && functions_used.any?) ||
            (request.tool_choice.type == "tool" && functions_used.include?(request.tool_choice.name))

            request.tool_choice = nil
          end
        end

        super
      end

      def api_prompt_execute(parameters)
        unless parameters[:stream]
          client.messages.create(**parameters)
        else
          client.messages.stream(**parameters.except(:stream)).each(&parameters[:stream])
          nil
        end
      rescue ::Anthropic::Errors::APIConnectionError => exception
        raise exception.cause
      end

      # @return void
      def process_stream_chunk(api_response_chunk)
        api_response_chunk = api_response_chunk.as_json.deep_symbolize_keys

        broadcast_stream_open

        case api_response_chunk[:type].to_sym
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
          process_finished if message_stack.last[:stop_reason]
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

      # @return void
      def process_function_calls(api_function_calls)
        content = api_function_calls.map do |api_function_call|
          process_tool_call_function(api_function_call)
        end

        message = Anthropic::Requests::Messages::User.new(content:)

        message_stack.push(message.to_hc)
      end

      def process_tool_call_function(api_function_call)
        results = tools_function.call(
          api_function_call[:name], **api_function_call[:input]
        )

        Anthropic::Requests::ContentBlocks::ToolResult.new(
          tool_use_id: api_function_call[:id],
          content:     results.to_json,
        )
      end

      def process_finished_extract_messages(api_response)
        return unless api_response

        [ api_response.as_json.deep_symbolize_keys ]
      end

      def process_finished_extract_function_calls
        message_stack.pluck(:content).flatten.select { it in { type: "tool_use" } }.map do |api_function_call|
          json_buf = api_function_call.delete(:json_buf)
          api_function_call[:input] = JSON.parse(json_buf, symbolize_names: true) if json_buf
          api_function_call
        end
      end
    end
  end
end
