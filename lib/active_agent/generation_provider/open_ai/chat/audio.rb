# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Chat
        class Audio < Common::BaseModel
          # Voice to use for audio output
          attribute :voice, :string

          # Audio format
          attribute :format, :string

          validates :voice, inclusion: { in: %w[alloy ash ballad coral echo fable onyx nova shimmer verse] }, allow_nil: true
          validates :format, inclusion: { in: %w[wav mp3 flac opus pcm16] }, allow_nil: true
        end
      end
    end
  end
end
