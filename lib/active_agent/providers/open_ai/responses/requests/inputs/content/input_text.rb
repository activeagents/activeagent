# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            module Content
              # Text content part
              class InputText < Base
                attribute :type, :string, as: "input_text"
                attribute :text, :string

                validates :text, presence: true
              end
            end
          end
        end
      end
    end
  end
end
