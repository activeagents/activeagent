# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Messages
          # Assistant message - messages sent by the model
          class Assistant < Base
            attribute :role, :string, as: "assistant"

            # Content can be:
            # - A string (shorthand for single text block)
            # - An array of content blocks (text, thinking, tool_use, etc.)
            validates :content, presence: true

            # To discard these unsupported field when packing the messages out again
            def usage=(value); end
            def id=(value); end
            def model=(value); end
            def stop_reason=(value); end
            def stop_sequence=(value); end
            def type=(value); end

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
