# frozen_string_literal: true

require_relative "../open_ai/chat/_types"
require_relative "options"

module ActiveAgent
  module Providers
    module Requesty
      # ActiveModel type for casting and serializing Requesty requests.
      #
      # Requesty is OpenAI-compatible, so requests use the same shape as the
      # OpenAI Chat API. This delegates entirely to OpenAI::Chat::RequestType.
      RequestType = ActiveAgent::Providers::OpenAI::Chat::RequestType
    end
  end
end
