# frozen_string_literal: true

module ActiveAgent
  module Providers
    # Typed provider failures, normalized across vendor SDKs.
    #
    # Every vendor raises its own exception classes for the same underlying
    # conditions (rate limits, context overflows, content filters, outages),
    # which makes retry/backoff/fallback policy impossible to express
    # portably. The taxonomy classifies vendor errors into a small set of
    # framework types — the original exception is preserved as +#cause+, so
    # nothing is lost.
    #
    # @example Portable retry policy
    #   rescue_from ActiveAgent::Providers::Errors::RateLimited do |error|
    #     retry_job wait: 30.seconds
    #   end
    #
    # @example Fallback on outage
    #   rescue_from ActiveAgent::Providers::Errors::ServiceUnavailable do |error|
    #     FallbackAgent.with(params).ask.generate_later
    #   end
    module Errors
      # Base class for normalized provider failures.
      class ProviderError < StandardError
        # @return [Integer, nil] HTTP status from the vendor error, when known
        attr_reader :status

        # @return [String, nil] provider tag (e.g. "Anthropic", "OpenAI::Chat")
        attr_reader :provider_tag

        def initialize(message = nil, status: nil, provider_tag: nil)
          super(message)
          @status = status
          @provider_tag = provider_tag
        end
      end

      # 429s / vendor rate & quota limits. Retryable with backoff.
      class RateLimited < ProviderError; end

      # The prompt exceeded the model's context window. Not retryable
      # without shrinking the input.
      class ContextLengthExceeded < ProviderError; end

      # Invalid, expired, or unauthorized credentials (401/403).
      class AuthenticationFailed < ProviderError; end

      # The vendor's safety layer refused the request or response.
      class ContentFiltered < ProviderError; end

      # Vendor-side failure or overload (5xx, timeouts, connection drops).
      # Retryable; a natural trigger for provider fallback.
      class ServiceUnavailable < ProviderError; end

      # Malformed or unsupported request the vendor rejected (400/422)
      # that doesn't classify more specifically.
      class InvalidRequest < ProviderError; end

      # Classifies vendor SDK exceptions into the taxonomy. Unrecognizable
      # exceptions (including ordinary Ruby errors) pass through untouched —
      # only errors that look like vendor API failures are normalized.
      module Taxonomy
        # Vendor SDK class names (demodulized) → taxonomy class. Covers the
        # official anthropic/openai gems and SDKs following their naming.
        NAME_MAP = {
          "RateLimitError" => RateLimited,
          "AuthenticationError" => AuthenticationFailed,
          "PermissionDeniedError" => AuthenticationFailed,
          "ContentFilterError" => ContentFiltered,
          "InternalServerError" => ServiceUnavailable,
          "APIConnectionError" => ServiceUnavailable,
          "APIConnectionTimeoutError" => ServiceUnavailable,
          "APITimeoutError" => ServiceUnavailable,
          "OverloadedError" => ServiceUnavailable,
          "ServiceUnavailableError" => ServiceUnavailable,
          "BadRequestError" => InvalidRequest,
          "UnprocessableEntityError" => InvalidRequest
        }.freeze

        STATUS_MAP = {
          400 => InvalidRequest,
          401 => AuthenticationFailed,
          403 => AuthenticationFailed,
          408 => ServiceUnavailable,
          422 => InvalidRequest,
          429 => RateLimited,
          529 => ServiceUnavailable # Anthropic "overloaded"
        }.freeze

        CONTEXT_LENGTH_PATTERN = /context length|context_length|maximum context|context window|too many tokens|prompt is too long|input (?:is )?too long/i
        CONTENT_FILTER_PATTERN = /content (?:filter|policy|management)|filtered due to|blocked by|safety (?:system|filter)/i

        class << self
          # @param exception [Exception]
          # @param provider_tag [String, nil]
          # @return [Exception] a taxonomy error, or the original exception
          #   when it doesn't classify
          def normalize(exception, provider_tag: nil)
            return exception if exception.is_a?(ProviderError)

            klass = classify(exception)
            return exception unless klass

            klass.new(exception.message, status: status_of(exception), provider_tag: provider_tag)
          end

          # @return [Class, nil]
          def classify(exception)
            name = exception.class.name.to_s.demodulize
            status = status_of(exception)
            api_error = NAME_MAP.key?(name) || !status.nil?
            return nil unless api_error

            message = exception.message.to_s
            return ContextLengthExceeded if CONTEXT_LENGTH_PATTERN.match?(message)
            return ContentFiltered if CONTENT_FILTER_PATTERN.match?(message)

            NAME_MAP[name] || STATUS_MAP[status] || (status && status >= 500 ? ServiceUnavailable : nil)
          end

          # @return [Integer, nil]
          def status_of(exception)
            [ :status, :status_code, :http_status, :code ].each do |reader|
              next unless exception.respond_to?(reader)

              value = begin
                exception.public_send(reader)
              rescue StandardError
                nil
              end
              return value if value.is_a?(Integer)
            end
            nil
          end
        end
      end
    end
  end
end
