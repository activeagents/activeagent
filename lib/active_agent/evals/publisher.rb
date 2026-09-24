# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module ActiveAgent
  module Evals
    # Publishes a completed report without replaying the agent. The caller must
    # retain run_id when retrying: compatible collectors treat that identity as
    # immutable within the authenticated account. Delivery is blocking and does
    # not follow redirects with the account's bearer credential.
    class Publisher
      DEFAULT_ENDPOINT = "https://api.activeagents.ai/v1/evaluations"
      MAX_BYTES = 2 * 1024 * 1024
      DETAIL_LIMIT = 200

      # Raised for every failed delivery.
      #
      # @!attribute [r] status
      #   @return [Integer, nil] the collector's HTTP status for a rejection, nil otherwise
      # @!attribute [r] detail
      #   @return [String, nil] the collector's sanitized explanation of a rejection, if it gave one
      class Error < StandardError
        attr_reader :status, :detail

        def initialize(message = nil, status: nil, detail: nil, retryable: false)
          super(message)
          @status = status
          @detail = detail
          @retryable = retryable
        end

        # Returns true when delivering the same report under the same run_id
        # again may succeed.
        def retryable?
          @retryable
        end
      end

      # Whether each rejection status is retryable, and what the caller should
      # do about it. Other statuses fall back to the rules in +rejection+.
      REJECTIONS = {
        409 => [ false, "the collector holds a different report under this run_id; never retry this report with the same run_id" ],
        413 => [ false, "the report exceeds the collector's size limit; publish a smaller selection" ],
        422 => [ false, "correct what the collector refused before retrying" ],
        429 => [ true, "the collector's quota or rate limit was reached; retain the report and run_id and retry later" ]
      }.freeze

      def initialize(api_key:, endpoint: DEFAULT_ENDPOINT, timeout: 10, open_timeout: 10)
        @uri = URI.parse(endpoint.to_s)
        unless @uri.is_a?(URI::HTTP) && @uri.host && !@uri.userinfo && !@uri.query && !@uri.fragment
          raise ArgumentError, "Evaluation endpoint must be an HTTP(S) URL without credentials, query or fragment"
        end
        unless @uri.scheme == "https" || %w[localhost 127.0.0.1 ::1].include?(@uri.hostname)
          raise ArgumentError, "Evaluation endpoint requires HTTPS except on loopback hosts"
        end
        raise ArgumentError, "Evaluation API key is required" if api_key.to_s.strip.empty?

        @api_key = api_key.to_s
        @timeout = Float(timeout)
        @open_timeout = Float(open_timeout)
        unless [ @timeout, @open_timeout ].all? { |value| value.finite? && value.positive? }
          raise ArgumentError, "Evaluation delivery timeouts must be positive and finite"
        end
      rescue URI::InvalidURIError
        raise ArgumentError, "Evaluation endpoint is not a valid URL"
      end

      # report may be a Report or its saved JSON hash. Full prompts, answers and
      # tool results are included; applications should make publication opt-in.
      def call(report:, run_id:, source:, agent_name:, suite:)
        identities = { "run_id" => run_id, "source" => source, "agent_name" => agent_name, "suite" => suite }
        identities.each do |key, value|
          raise ArgumentError, "#{key} must be a nonempty string" unless value.is_a?(String) && !value.strip.empty?
        end
        body = JSON.generate(identities.merge("version" => 1, "report" => report.to_h))
        raise Error, "Evaluation report exceeds the 2 MiB delivery limit; publish a smaller selection" if body.bytesize > MAX_BYTES

        http = Net::HTTP.new(@uri.hostname, @uri.port)
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @timeout
        http.write_timeout = @timeout
        request = Net::HTTP::Post.new(@uri.request_uri)
        request["Authorization"] = "Bearer #{@api_key}"
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request.body = body
        response = http.request(request)
        raise rejection(response) unless %w[200 201].include?(response.code)

        receipt = JSON.parse(response.body)
        unless receipt.is_a?(Hash) && receipt["run_id"] == run_id && receipt["status"] == "complete" && receipt["id"] && receipt["evaluation_id"]
          raise Error.new("Evaluation collector returned an invalid completion receipt; retain the report and run_id for retry", retryable: true)
        end
        receipt
      rescue JSON::ParserError
        raise Error.new("Evaluation collector returned invalid JSON; retain the report and run_id for retry", retryable: true)
      rescue IOError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
        raise Error.new("Evaluation delivery failed (#{e.class}); retain the report and run_id for retry", retryable: true)
      end

      private

      def rejection(response)
        status = response.code.to_i
        retryable, guidance = REJECTIONS.fetch(status) do
          if status == 408 || (500..599).cover?(status)
            [ true, "retain the report and run_id for retry" ]
          else
            [ false, "retain the report and run_id, and resolve the rejection before retrying" ]
          end
        end
        detail = collector_detail(response.body)
        reason = detail ? "HTTP #{status}: #{detail}" : "HTTP #{status}"
        Error.new("Evaluation delivery rejected (#{reason}); #{guidance}", status: status, detail: detail, retryable: retryable)
      end

      # Returns the +error+ string of a JSON object body, or nil for any other
      # body. Control characters and runs of whitespace become one space, the
      # API key becomes [FILTERED], and the result is cut to DETAIL_LIMIT
      # characters: `"answer\n\tis required"` → `"answer is required"`.
      def collector_detail(body)
        parsed = JSON.parse(body.to_s)
        message = parsed["error"] if parsed.is_a?(Hash)
        return unless message.is_a?(String)

        detail = message.scrub.gsub(/[[:space:]\p{C}]+/, " ").strip.gsub(@api_key, "[FILTERED]")
        return if detail.empty?

        detail.length > DETAIL_LIMIT ? "#{detail[0, DETAIL_LIMIT - 1].rstrip}…" : detail
      rescue JSON::ParserError, EncodingError
        nil
      end
    end
  end
end
