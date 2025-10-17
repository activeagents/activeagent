# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Messages
          # User message - messages sent by the user
          class User < Base
            attribute :role, :string, as: "user"

            # Content can be:
            # - A string (shorthand for single text block)
            # - An array of content blocks (text, image, document, etc.)
            validates :content, presence: true

            def initialize(**kwargs)
              # Convert string content to array format if needed
              if kwargs[:content].is_a?(String)
                kwargs[:content] = [ { type: "text", text: kwargs[:content] } ]
              end

              super(**kwargs)
            end
          end
        end
      end
    end
  end
end
