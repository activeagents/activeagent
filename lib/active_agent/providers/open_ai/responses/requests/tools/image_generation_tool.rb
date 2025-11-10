# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Tools
            # Image generation tool
            class ImageGenerationTool < Base
              attribute :type, :string, as: "image_generation"
              attribute :background, :string, default: "auto" # Optional: "transparent", "opaque", or "auto"
              attribute :input_fidelity, :string, default: "low" # Optional: "high" or "low"
              attribute :input_image_mask # Optional: hash with image_url and/or file_id
              attribute :model, :string, default: "gpt-image-1" # Optional: model to use
              attribute :moderation, :string, default: "auto" # Optional: moderation level
              attribute :output_compression, :integer, default: 100 # Optional: compression level
              attribute :output_format, :string, default: "png" # Optional: "png", "webp", or "jpeg"
              attribute :partial_images, :integer, default: 0 # Optional: 0-3
              attribute :quality, :string, default: "auto" # Optional: "low", "medium", "high", or "auto"
              attribute :size, :string, default: "auto" # Optional: "1024x1024", "1024x1536", "1536x1024", or "auto"

              validates :background, inclusion: { in: %w[transparent opaque auto] }, allow_nil: true
              validates :input_fidelity, inclusion: { in: %w[high low] }, allow_nil: true
              validates :output_format, inclusion: { in: %w[png webp jpeg] }, allow_nil: true
              validates :partial_images, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 3 }, allow_nil: true
              validates :quality, inclusion: { in: %w[low medium high auto] }, allow_nil: true
              validates :size, inclusion: { in: %w[1024x1024 1024x1536 1536x1024 auto] }, allow_nil: true
            end
          end
        end
      end
    end
  end
end
