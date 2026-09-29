# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require "zlib"

module ActiveAgent
  module Evals
    # Publishes a completed report without replaying the agent. The caller must
    # retain run_id when retrying: compatible collectors treat that identity as
    # immutable within the authenticated account. Delivery is blocking and does
    # not follow redirects with the account's bearer credential. +verify!+ asks
    # the collector whether it is up and accepts the key before a run is paid for.
    #
    # Every failure to deliver raises Error. Invalid arguments raise
    # ArgumentError before anything is sent.
    class Publisher
      DEFAULT_ENDPOINT = "https://api.activeagents.ai/v1/evaluations"
      MAX_BYTES = 2 * 1024 * 1024
      DETAIL_LIMIT = 200

      # @return [String] the collector URL reports go to
      attr_reader :endpoint

      # Raised for every failed delivery. Only a network failure keeps the
      # underlying error as its +cause+, so neither the response nor the
      # report reaches a log through the exception chain.
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
        401 => [ false, "the collector refused the API key; check the key against the collector's account" ],
        403 => [ false, "the account may not store this report until an operator acts, for example on a cap on observed agents, evaluations or scenarios; resolve that before retrying" ],
        404 => [ false, "nothing at the endpoint takes evaluation reports; check that it is a collector's /v1/evaluations or <mount>/api/evaluation_reports URL" ],
        409 => [ false, "the collector already holds a different report under this run_id; never retry this report with the same run_id" ],
        413 => [ false, "the report exceeds the collector's size limit; publish a smaller selection" ],
        415 => [ false, "the collector did not receive application/json; check anything between the publisher and the collector that rewrites the Content-Type" ],
        422 => [ false, "correct what the collector refused before retrying" ],
        429 => [ true, "the account is over its quota or rate limit; retain the report and run_id and retry later" ],
        501 => [ false, "the collector has no evaluation store; migrate the install, or publish to one generated with evaluation tables" ]
      }.freeze

      # The key is sent as a bearer token and filtered from the collector's
      # explanation, so it is limited to visible ASCII: the sanitizer in
      # +collector_detail+ never alters it, and an echo of it always matches.
      def initialize(api_key:, endpoint: DEFAULT_ENDPOINT, timeout: 10, open_timeout: 10)
        @uri = URI.parse(endpoint.to_s)
        unless @uri.is_a?(URI::HTTP) && @uri.host && !@uri.userinfo && !@uri.query && !@uri.fragment
          raise ArgumentError, "Evaluation endpoint must be an HTTP(S) URL without credentials, query or fragment"
        end
        unless @uri.scheme == "https" || %w[localhost 127.0.0.1 ::1].include?(@uri.hostname)
          raise ArgumentError, "Evaluation endpoint requires HTTPS except on loopback hosts"
        end
        @endpoint = @uri.to_s

        @api_key = api_key.to_s.strip
        raise ArgumentError, "Evaluation API key is required" if @api_key.empty?
        unless @api_key.match?(/\A[\x21-\x7E]+\z/)
          raise ArgumentError, "Evaluation API key must contain only visible ASCII characters"
        end

        @timeout = Float(timeout, exception: false)
        @open_timeout = Float(open_timeout, exception: false)
        unless [ @timeout, @open_timeout ].all? { |value| value&.finite? && value.positive? }
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
        body = encode(identities.merge("version" => 1, "report" => report_hash(report)))
        raise Error, "Evaluation report exceeds the 2 MiB delivery limit; publish a smaller selection" if body.bytesize > MAX_BYTES

        deliver("retain the report and run_id for retry") do
          response = post(body)
          raise rejection(response) unless %w[200 201].include?(response.code)

          receipt = JSON.parse(response.body.to_s)
          unless receipt.is_a?(Hash) && receipt["run_id"] == run_id && receipt["status"] == "complete" && receipt["id"] && receipt["evaluation_id"]
            raise Error.new("Evaluation collector returned an invalid completion receipt; retain the report and run_id for retry", retryable: true)
          end
          receipt
        end
      end

      # Returns true when the collector is up and accepts the API key, without
      # storing anything. It posts an empty JSON object, which a compatible
      # collector authenticates, parses, and then refuses with a 422 whose
      # +error+ names +version+, as not a version-1 report. That refusal, and
      # only that one, is the ready answer. Call it before an expensive run, so
      # a stopped collector or a refused key fails before the first model call
      # rather than after the last one.
      #
      # Raises Error for anything else: a rejection other than 422, with the
      # status, detail and guidance +call+ would carry (401 for a refused key,
      # 404 when nothing at the endpoint takes reports); a retryable delivery
      # failure when the collector cannot be reached; a 422 that says anything
      # else; or a collector that stores the empty object. The last two mean the
      # endpoint is not a compatible collector.
      def verify!
        deliver("start the collector or check the endpoint, then verify again") do
          response = post("{}")
          if response.code == "422"
            detail = collector_detail(response.body)
            next true if detail&.match?(/\bversion\b/)

            raise Error.new("Evaluation collector answered HTTP 422 without refusing the empty envelope as a version-1 report, " \
                            "so it is not a compatible collector; check the endpoint", status: 422, detail: detail)
          end
          raise rejection(response) unless %w[200 201].include?(response.code)

          raise Error, "Evaluation collector stored an empty report, so it is not a compatible collector; check the endpoint"
        end
      end

      private

      # Posts +body+ to the endpoint with the bearer key and the delivery timeouts.
      def post(body)
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
        http.request(request)
      end

      # Runs one exchange with the collector, turning every failure to reach it
      # or to read its answer into a retryable Error that quotes nothing from
      # the response and ends with +guidance+, what the caller should do next.
      # An Error the block raises passes through unchanged.
      def deliver(guidance)
        yield
      rescue JSON::ParserError
        # The parser's message quotes the body.
        raise Error.new("Evaluation collector returned invalid JSON; #{guidance}", retryable: true), cause: nil
      rescue Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::Error => e
        # These messages can quote the response's status line, headers or body.
        raise Error.new("Evaluation collector returned a malformed response (#{e.class}); #{guidance}", retryable: true), cause: nil
      rescue IOError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
        raise Error.new("Evaluation delivery failed (#{e.class}); #{guidance}", retryable: true)
      end

      def report_hash(report)
        hash = report.to_h if report.respond_to?(:to_h) && !report.nil? && !report.is_a?(Array)
        raise ArgumentError, "report must be a Report or its saved JSON hash" unless hash.is_a?(Hash)

        hash
      end

      # Returns the envelope as JSON. A report holding invalid UTF-8, NaN,
      # Infinity or nesting over JSON's depth limit raises a non-retryable
      # Error, without the generator's message, which can quote the report.
      def encode(envelope)
        JSON.generate(envelope)
      rescue JSON::JSONError, EncodingError => e
        raise Error.new("Evaluation report cannot be encoded as JSON (#{e.class}); correct the report before publishing"), cause: nil
      end

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
