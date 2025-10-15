# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Chat
        class StreamOptions < Common::BaseModel
          # Include usage information in the stream
          attribute :include_usage, :boolean

          validates :include_usage, inclusion: { in: [ true, false ] }, allow_nil: true
        end
      end
    end
  end
end
