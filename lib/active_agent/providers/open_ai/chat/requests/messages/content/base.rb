# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            module Content
              # Base class for content parts
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
end
