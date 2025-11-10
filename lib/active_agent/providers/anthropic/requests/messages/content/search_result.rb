# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Content
          # Search result content block
          class SearchResult < Base
            attribute :type, :string, as: "search_result"
            attribute :source, :string
            attribute :title, :string
            attribute :content # Array of text blocks
            attribute :citations # Optional citations config
            attribute :cache_control # Optional cache control

            validates :source, presence: true
            validates :title, presence: true
            validates :content, presence: true
          end
        end
      end
    end
  end
end
