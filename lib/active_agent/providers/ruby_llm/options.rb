# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module RubyLLM
      # Configuration options for the RubyLLM provider.
      #
      # RubyLLM manages its own API keys via RubyLLM.configure, so no
      # provider-specific API key attributes are needed here.
      class Options < Common::BaseModel
        attribute :model, :string
        # Pins which RubyLLM backend serves the model (RubyLLM's provider:,
        # e.g. :vertexai, :gemini, :bedrock). A model ID served by several
        # backends otherwise resolves by RubyLLM's registry preference.
        attribute :platform, :string
        # Pins which of the backend's wire protocols carries a request
        # (RubyLLM's protocol:, e.g. :chat_completions or :responses for
        # OpenAI). ruby_llm 2.x only; without it RubyLLM's own setting
        # applies, and for OpenAI that defaults to :responses.
        attribute :protocol, :string
        attribute :temperature, :float
        attribute :max_tokens, :integer

        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)
          super(**deep_compact(kwargs))
        end

        def extra_headers
          {}
        end
      end
    end
  end
end
