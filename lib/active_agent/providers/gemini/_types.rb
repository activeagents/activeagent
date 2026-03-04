# frozen_string_literal: true

require_relative "options"
require_relative "../open_ai/chat/_types"

module ActiveAgent
  module Providers
    module Gemini
      # Reuse OpenAI Chat request type (same API format)
      RequestType = OpenAI::Chat::RequestType
    end
  end
end
