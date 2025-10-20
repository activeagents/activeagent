# frozen_string_literal: true

require_relative "base"
require_relative "sources/_types"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Content
          # Image content block
          class Image < Base
            attribute :type, :string, as: "image"
            attribute :source, Sources::SourceType.new # Can be base64, url, or file
            attribute :cache_control # Optional cache control

            validates :source, presence: true
          end
        end
      end
    end
  end
end
