# frozen_string_literal: true

require_relative "base"
require_relative "content/_types"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            # User message - messages sent by an end user
            class User < Base
              attribute :role, :string, as: "user"
              attribute :content, Content::ContentsType.new # String or array of content parts
              attribute :name, :string # Optional name for the participant

              validates :content, presence: true

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
