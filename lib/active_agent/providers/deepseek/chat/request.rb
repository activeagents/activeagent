# frozen_string_literal: true

require_relative "../../open_ai/chat/request"

module ActiveAgent
  module Providers
    module DeepSeek
      module Chat
        # Chat completion request for DeepSeek.
        #
        # Extends OpenAI::Chat::Request to turn thinking mode **off** by default.
        #
        # DeepSeek runs thinking by default and does not require opting in. For
        # the extraction and classification work agents typically do, that
        # reasoning is charged for and thrown away — measured against
        # `deepseek-flash`, "return a currency code as JSON" cost 87 output
        # tokens with thinking left alone (80 of them reasoning) and 7 with it
        # disabled.
        #
        # Opt back in per prompt when the task warrants it:
        #
        #   prompt "…", thinking: { type: "enabled" }
        #
        # DeepSeek also ignores temperature, presence_penalty and
        # frequency_penalty while thinking is on, so disabling it makes those
        # parameters take effect again.
        #
        # @see OpenAI::Chat::Request
        # @see https://api-docs.deepseek.com/guides/thinking_mode
        class Request < OpenAI::Chat::Request
          # Model used when a prompt does not name one.
          DEFAULT_MODEL = "deepseek-flash"

          # Thinking off, unless the caller says otherwise.
          DEFAULT_THINKING = { type: "disabled" }.freeze

          # @param params [Hash] request parameters
          # @option params [String] :model (deepseek-flash)
          # @option params [Hash] :thinking ({ type: "disabled" }) DeepSeek's
          #   non-standard thinking toggle; `{ type: "enabled" }` opts back in
          def initialize(**params)
            params[:model]    ||= DEFAULT_MODEL
            params[:thinking] ||= DEFAULT_THINKING.dup

            super
          end
        end
      end
    end
  end
end
