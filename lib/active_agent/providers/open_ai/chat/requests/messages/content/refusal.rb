# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            module Content
              # Refusal content part (used in assistant messages)
              class Refusal < Base
                attribute :type, :string, as: "refusal"
                attribute :refusal, :string

                validates :refusal, presence: true
              end
            end
          end
        end
      end
    end
  end
end
