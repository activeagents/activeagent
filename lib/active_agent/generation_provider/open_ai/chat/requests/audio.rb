# frozen_string_literal: true

require_relative "../../../common/_base_model"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Chat
        module Requests
          class Audio < Common::BaseModel
            # Voice to use for audio output
            attribute :voice, :string

            # Audio format
            attribute :format, :string

            validates :voice, inclusion: { in: %w[alloy ash ballad coral echo fable nova onyx sage shimmer] }, allow_nil: true
            validates :format, inclusion: { in: %w[wav mp3 flac opus pcm16] }, allow_nil: true
          end
        end
      end
    end
  end
end
