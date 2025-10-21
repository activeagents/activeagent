# frozen_string_literal: true

require "active_agent/providers/common/model"
require_relative "content/_types"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Base class for input items in Responses API
            class Base < Common::BaseModel
              attribute :role, :string
              attribute :content, Content::ContentsType.new

              validates :role, inclusion: {
                in: %w[system user assistant developer tool],
                allow_nil: true
              }

              # Define content setter methods for different content types
              %i[text image document].each do |content_type|
                define_method(:"#{content_type}=") do |value|
                  self.content ||= []
                  self.content += [ { content_type => value } ]
                end
              end
            end
          end
        end
      end
    end
  end
end
