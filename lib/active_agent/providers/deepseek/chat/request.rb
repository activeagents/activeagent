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
              params[:messages] = wrap(params.delete(:instructions)).map { |text| { role: "system", content: text } } +
                                  wrap(params[:messages])
            end

            messages = wrap(params[:messages])
            return if messages.empty?

            params[:messages] = messages.map do |message|
              next message unless message.is_a?(Hash)

              key = role_key(message)
              next message unless key && message[key].to_s == "developer"

              # A copy: the messages are the caller's own hashes — the provider
              # keeps the very `context` the prompt was given — so rewriting one
              # in place would rewrite it for every other provider that prompt
              # reaches, and for every later reuse of the same context.
              message.dup.tap { |copy| copy[key] = "system" }
            end
          end

          # Wraps a value that may be a single item, a list, or absent.
          #
          # `Array(hash)` splits a lone Hash into pairs, which is not what a
          # single message or instruction means.
          #
          # @param value [Object, Array, nil]
          # @return [Array]
          def wrap(value)
            return [] if value.nil?
            return [ value ] if value.is_a?(Hash)

            Array(value)
          end

          # @param message [Hash]
          # @return [Symbol, String, nil] whichever key the message spells its
          #   role with, since a caller may use either
          def role_key(message)
            return :role if message.key?(:role)
            return "role" if message.key?("role")

            nil
          end
        end
      end
    end
  end
end
