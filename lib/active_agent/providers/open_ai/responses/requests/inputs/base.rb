# frozen_string_literal: true

require_relative "../../../../common/_base_model"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Base class for input items in Responses API
            class Base < Common::BaseModel
              attribute :role, :string
              attribute :content # Can be string or array of content parts

              validates :role, inclusion: {
                in: %w[system user assistant tool],
                allow_nil: true
              }
            end
          end
        end
      end
    end
  end
end
