# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Tools
            # Base class for tools
            class Base < Common::BaseModel
              attribute :type, :string

              validates :type, inclusion: { in: %w[function custom] }
            end
          end
        end
      end
    end
  end
end
