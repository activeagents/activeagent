# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            module Content
              # Image content part
              class Image < Base
                attribute :type, :string, as: "image_url"
                attribute :image_url, default: -> { {} }

                validates :image_url, presence: true

                # Nested image_url object
                def image_url=(value)
                  case value
                  when Hash
                    super(value.symbolize_keys)
                  when String
                    super({ url: value })
                  else
                    super(value)
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
