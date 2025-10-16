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
                attribute :image_url # Can be string (URL or data URI) or object with url and detail

                validates :image_url, presence: true
              end
            end
          end
        end
      end
    end
  end
end
