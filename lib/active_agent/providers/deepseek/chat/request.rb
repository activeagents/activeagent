# frozen_string_literal: true

require_relative "../../open_ai/chat/request"

module ActiveAgent
  module Providers
    module DeepSeek
      module Chat
        # Chat completion request for DeepSeek.
        #
        # Extends OpenAI::Chat::Request with DeepSeek's defaults for the two
        # things OpenAI cannot supply: the model name and the message roles.
        #
        # Everything else is left to DeepSeek. Its API is the authority on how
        # it wants to be called, and a library that second-guesses that gets
        # stale as the provider tunes itself — thinking mode, for one, is on by
        # default and is the provider's call to make.
        #
        # Thinking is worth knowing about either way, because it changes what
        # the other parameters do: DeepSeek bills the reasoning whether or not
        # the answer needed it, and it ignores temperature, presence_penalty and
        # frequency_penalty while thinking. A one-line JSON extraction measured
        # 83 output tokens at DeepSeek's default against 7 with thinking
        # disabled, so a prompt that wants those sampling parameters to bite, or
        # wants to skip paying for reasoning it discards, can opt out itself:
        #
        #   prompt "…", thinking: { type: "disabled" }
        #
        # @see OpenAI::Chat::Request
        # @see https://api-docs.deepseek.com/guides/thinking_mode
        class Request < OpenAI::Chat::Request
          # Model used when a prompt does not name one. DeepSeek has no default
          # of its own — the API requires `model` — so this is a convenience,
          # not an override.
          DEFAULT_MODEL = "deepseek-flash"

          # @param params [Hash] request parameters
          # @option params [String] :model (deepseek-flash)
          # @option params [Hash] :thinking DeepSeek's own thinking toggle,
          #   passed through untouched; `{ type: "disabled" }` opts out
          def initialize(**params)
            params[:model] ||= DEFAULT_MODEL

            demote_developer_roles!(params)

            super
          end

          private

          # Rewrites `developer` messages to `system` before the OpenAI
          # transforms run.
          #
          # DeepSeek accepts system, user, assistant, tool and latest_reminder,
          # and nothing else. It rejects the rest rather than ignoring them:
          #
          #   messages[0].role: unknown variant `developer`, expected one of
          #   `system`, `user`, `assistant`, `tool`, `latest_reminder`
          #
          # That is a 422 on the whole request, and `developer` is the role it
          # bites on: OpenAI treats it as the successor to `system`, so the
          # OpenAI transforms express `instructions` as a developer message and
          # any agent using them fails outright here.
          #
          # @param params [Hash] request parameters, mutated in place
          # @return [void]
          def demote_developer_roles!(params)
            if params.key?(:instructions)
              # One message per instruction to start. The request cleanup then
              # merges consecutive same-role messages into a single message
              # with content parts, which DeepSeek accepts — unlike `developer`,
              # the part that actually fails.
              params[:messages] = Array(params.delete(:instructions)).map { |text| { role: "system", content: text } } +
                                  Array(params[:messages] || [])
            end

            Array(params[:messages]).each do |message|
              next unless message.is_a?(Hash)

              key = message.key?(:role) ? :role : (message.key?("role") ? "role" : nil)
              next unless key && message[key].to_s == "developer"

              message[key] = "system"
            end
          end
        end
      end
    end
  end
end
