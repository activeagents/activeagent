# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    class Response
      attr_reader :message, :prompt, :raw_response

      def initialize(prompt:, message: nil, raw_response: nil)
        @prompt = prompt
        @message = message || prompt.message
        @raw_response = raw_response
      end
    end
  end
end
