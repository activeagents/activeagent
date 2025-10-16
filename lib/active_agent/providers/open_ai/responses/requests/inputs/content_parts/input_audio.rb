# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            module ContentParts
              # Audio content part
              class InputAudio < Base
                attribute :type, :string, as: "input_audio"
                attribute :input_audio # Object containing audio properties

                validates :type, presence: true
                validates :input_audio, presence: true
              end
            end
          end
        end
      end
    end
  end
end
