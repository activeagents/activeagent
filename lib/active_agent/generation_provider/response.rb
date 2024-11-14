# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    class Response
      attr_reader :message, :prompt, :raw_response

      def initialize(prompt:, message:, raw_response: nil)
        @message = message
        @prompt = prompt
        @raw_response = raw_response
      end
    end
  end
end
