# frozen_string_literal: true

require_relative "options"
require_relative "../open_ai/chat/_types"
require_relative "../open_ai/embedding/_types"

module ActiveAgent
  module Providers
    module Gemini
      # Reuse OpenAI Chat request type (same API format)
      RequestType = OpenAI::Chat::RequestType

      # Reuse OpenAI Embedding types (same API format)
      module Embedding
        RequestType = OpenAI::Embedding::RequestType
      end
    end
  end
end
