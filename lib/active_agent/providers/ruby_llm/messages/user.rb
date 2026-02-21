# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module RubyLLM
      module Messages
        # User message for RubyLLM provider.
        class User < Base
          attribute :role, :string, as: "user"

          validates :content, presence: true
        end
      end
    end
  end
end
