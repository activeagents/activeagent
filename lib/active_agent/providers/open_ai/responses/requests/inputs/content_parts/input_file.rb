# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            module ContentParts
              # File content part
              class InputFile < Base
                attribute :type, :string, as: "input_file"
                attribute :filename, :string
                attribute :file_data, :string # Base64 encoded file data

                validates :filename, presence: true
                validates :file_data, presence: true
              end
            end
          end
        end
      end
    end
  end
end
