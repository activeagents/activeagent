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

          # @!attribute [r] timings
          #   Client-observed stream latency for each API call of this
          #   generation, in call order. Each entry may carry, measured from
          #   that call's own request start:
          #
          #   - +:first_chunk_ms+ — first streamed chunk of any kind arrived
          #   - +:first_token_ms+ — first non-empty content delta arrived
          #
          #   A call that did not stream contributes an empty entry: a
          #   non-streamed response has no observable first token.
          #
          #   @return [Array<Hash>]
          attribute :timings, default: -> { [] }, writable: false

          # The most recent message in the conversational stack
          def message
            messages.last
          end

          # Time to first token, in milliseconds — the gap a user stares at:
          # from the request leaving the client to the first visible content
          # delta arriving. Measured client-side (no provider used here
          # reports it on the wire), so network time to the provider is
          # included. Only a streamed generation has one; +nil+ otherwise.
          #
          # For a tool-calling generation this is the first turn that
          # produced text, timed from that turn's own request start.
          #
          # @return [Float, nil]
          def ttft_ms
            first_timing_value(:first_token_ms)
          end

          # Milliseconds until the provider's first streamed chunk of any
          # kind — the "provider is responding" mark. Arrives at or before
          # {#ttft_ms}: handshake chunks (e.g. Anthropic's message_start)
          # carry no text. +nil+ for non-streamed generations.
          #
          # @return [Float, nil]
          def time_to_first_chunk_ms
            first_timing_value(:first_chunk_ms)
          end

          private

          def first_timing_value(key)
            Array(timings).each do |timing|
              next unless timing.respond_to?(:[])

              value = timing[key] || timing[key.to_s]
              return value if value
            end

            nil
          end
        end
      end
    end
  end
end
