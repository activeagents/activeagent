# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ContentBlocks
          # Document content block
          class Document < Base
            attribute :type, :string, as: "document"
            attribute :source # Can be base64, text, url, or file
            attribute :title, :string # Optional title
            attribute :context, :string # Optional context
            attribute :citations # Optional citations config
            attribute :cache_control # Optional cache control

            validates :source, presence: true
          end
        end
      end
    end
  end
end
