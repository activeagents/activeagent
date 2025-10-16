# frozen_string_literal: true

require_relative "../../../../../common/_base_model"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            module ContentParts
              # Base class for content parts
              class Base < Common::BaseModel
                attribute :type, :string
              end
            end
          end
        end
      end
    end
  end
end
