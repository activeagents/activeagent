# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          class StreamOptions < Common::BaseModel
            # Include usage information in the stream
            attribute :include_usage, :boolean

            validates :include_usage, inclusion: { in: [ true, false ] }, allow_nil: true
          end
        end
      end
    end
  end
end
