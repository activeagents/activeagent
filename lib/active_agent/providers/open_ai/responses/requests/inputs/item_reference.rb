# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Item reference for referencing other items
            class ItemReference < Base
              attribute :type, :string, as: "item_reference"
              attribute :id, :string

              validates :id, presence: true
            end
          end
        end
      end
    end
  end
end
