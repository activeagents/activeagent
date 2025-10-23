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

          # The most recent message in the conversational stack
          def message
            messages.last
          end
        end
      end
    end
  end
end
