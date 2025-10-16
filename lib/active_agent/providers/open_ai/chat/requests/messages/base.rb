# frozen_string_literal: true

require_relative "../../../../common/_base_model"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            # Base class for all message types
            class Base < Common::BaseModel
              attribute :role, :string

              validates :role, presence: true

              def to_h
                super.compact
              end
            end
          end
        end
      end
    end
  end
end
