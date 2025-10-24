# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module TextFormats
            # Base class for text format configurations
            class Base < Common::BaseModel
              attribute :type, :string

              validates :type, inclusion: { in: %w[text json_object json_schema] }, allow_nil: false
            end
          end
        end
      end
    end
  end
end
