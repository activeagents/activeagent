# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module RubyLLM
      module Messages
        # System message for RubyLLM provider.
        class System < Base
          attribute :role, :string, as: "system"

          validates :content, presence: true
        end
      end
    end
  end
end
