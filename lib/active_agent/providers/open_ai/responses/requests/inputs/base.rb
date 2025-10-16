# frozen_string_literal: true

require_relative "../../../../common/_base_model"
require_relative "../types"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Base class for input items in Responses API
            class Base < Common::BaseModel
              attribute :role, :string
              attribute :content, Types::ContentType.new

              validates :role, inclusion: {
                in: %w[system user assistant developer tool],
                allow_nil: true
              }

              def to_hc
                super.tap do |hash|
                  if content.is_a?(Array) && content.one? && content.first.type == "input_text"
                    hash[:content] = content.first.text
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
