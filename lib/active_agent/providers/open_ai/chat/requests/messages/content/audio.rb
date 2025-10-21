# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            module Content
              # Audio content part
              class Audio < Base
                attribute :type, :string, as: "input_audio"
                attribute :input_audio, default: -> { {} }

                validates :input_audio, presence: true

                # Nested input_audio object
                def input_audio=(value)
                  case value
                  when Hash
                    super(value.symbolize_keys)
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
