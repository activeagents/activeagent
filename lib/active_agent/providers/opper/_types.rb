# frozen_string_literal: true

require_relative "../open_ai/chat/_types"
require_relative "options"

module ActiveAgent
  module Providers
    module Opper
      # ActiveModel type for casting and serializing Opper requests.
      #
      # Opper is OpenAI-compatible, so requests use the same shape as the
      # OpenAI Chat API. This delegates entirely to OpenAI::Chat::RequestType.
      RequestType = ActiveAgent::Providers::OpenAI::Chat::RequestType
    end
  end
end
