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
