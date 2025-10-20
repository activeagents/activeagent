# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Content
          module Sources
            # Base64-encoded image source
            class ImageBase64 < Base
              attribute :type, :string, as: "base64"
              attribute :media_type, :string
              attribute :data, :string

              validates :media_type, presence: true, inclusion: {
                in: %w[image/jpeg image/png image/gif image/webp]
              }
              validates :data, presence: true
            end
          end
        end
      end
    end
  end
end
