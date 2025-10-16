# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            module ContentParts
              # Image content part
              class InputImage < Base
                attribute :type, :string, as: "input_image"
                attribute :detail, :string, default: "auto" # One of: high, low, auto
                attribute :file_id, :string # Optional: ID of file to send
                attribute :image_url, :string # Optional: URL or base64 data URL

                validates :type, presence: true
                validates :detail, presence: true
              end
            end
          end
        end
      end
    end
  end
end
