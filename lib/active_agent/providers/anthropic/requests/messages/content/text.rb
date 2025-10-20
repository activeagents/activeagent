# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Content
          # Text content block
          class Text < Base
            attribute :type, :string, as: "text"
            attribute :text, :string
            attribute :cache_control # Optional cache control

            validates :text, presence: true
          end
        end
      end
    end
  end
end
