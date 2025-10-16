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
                attribute :file_data, :string # Optional: content of file to send
                attribute :file_id, :string # Optional: ID of file to send
                attribute :file_url, :string # Optional: URL of file to send
                attribute :filename, :string # Optional: name of file

                validates :type, presence: true
              end
            end
          end
        end
      end
    end
  end
end
