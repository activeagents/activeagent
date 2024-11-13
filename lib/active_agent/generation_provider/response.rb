# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    class Response
      attr_reader :message, :raw_response

      def initialize(message:, raw_response: nil)
        @raw_response = raw_response
        @message = message
      end
    end
  end
end
