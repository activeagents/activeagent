# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Content
          module Sources
            # Base class for all content sources
            class Base < Common::BaseModel
              attribute :type, :string

              validates :type, presence: true
            end
          end
        end
      end
    end
  end
end
