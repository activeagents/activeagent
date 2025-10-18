# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Common
      module Responses
        # Response model for embedding responses
        #
        # This class represents responses from embedding endpoints.
        # It includes the embedding data, the original context, raw API data,
        # and usage statistics.
        #
        # == Example
        #
        #   response = EmbedResponse.new(
        #     context: context_hash,
        #     data: [embedding_array],
        #     raw_response: { "usage" => { "prompt_tokens" => 10 } }
        #   )
        #
        #   response.data           #=> [[0.1, 0.2, ...]]
        #   response.prompt_tokens  #=> 10
        #   response.usage          #=> { "prompt_tokens" => 10, ... }
        class Embed < Base
          # The embedding data
          attribute :data, writable: false
        end
      end
    end
  end
end
