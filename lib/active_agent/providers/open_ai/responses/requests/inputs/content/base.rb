# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            module Content
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
