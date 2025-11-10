# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            module Content
              # Text content part
              class Text < Base
                attribute :type, :string, as: "text"
                attribute :text, :string

                validates :text, presence: true
              end
            end
          end
        end
      end
    end
  end
end
