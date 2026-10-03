# frozen_string_literal: true

require_relative "base"
require_relative "_types"
require_relative "message"

module ActiveAgent
  module Providers
    module Common
      module Responses
        # Response model for prompt/completion responses
        #
        # This class represents responses from conversational/completion endpoints.
        # It includes the generated messages, the original context, raw API data,
        # and usage statistics.
        #
        # == Example
        #
        #   response = PromptResponse.new(
        #     context: context_hash,
        #     messages: [message_object],
        #     raw_response: { "usage" => { "prompt_tokens" => 10 } }
        #   )
        #
        #   response.message        #=> <Message>
        #   response.prompt_tokens  #=> 10
        #   response.usage          #=> { "prompt_tokens" => 10, ... }
        class Prompt < Base
          # The list of messages from this conversation
          attribute :messages, Types::MessagesType.new, writable: false

          attribute :format, Types::FormatType.new, writable: false, default: {}

          # @!attribute [r] input_requests
          #   The questions tools put to the user, one per paused tool call.
          #   @return [Array<ActiveAgent::InputRequest>]
          attribute :input_requests, default: -> { [] }, writable: false

          # @!attribute [r] checkpoint
          #   What ActiveAgent::Generation#resume_now continues from, as a
          #   JSON-safe hash. It holds the conversation, so store it as
          #   carefully as the conversation itself.
          #   @return [Hash, nil]
          attribute :checkpoint, writable: false

          # The most recent message in the conversational stack
          def message
            messages.last
          end

          # Whether the generation paused because a tool asked the user for
          # input. The last message is then the assistant turn that made the
          # tool calls, not an answer.
          #
          # @return [Boolean]
          def awaiting_input?
            input_requests.present?
          end
        end
      end
    end
  end
end
