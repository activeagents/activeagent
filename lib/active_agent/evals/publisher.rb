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
      class Error < StandardError; end

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
        unless %w[200 201].include?(response.code)
          raise Error, "Evaluation delivery rejected (HTTP #{response.code}); retain the report and run_id for retry"
        end

        receipt = JSON.parse(response.body)
        unless receipt.is_a?(Hash) && receipt["run_id"] == run_id && receipt["status"] == "complete" && receipt["id"] && receipt["evaluation_id"]
          raise Error, "Evaluation collector returned an invalid completion receipt; retain the report and run_id for retry"
        end
        receipt
      rescue JSON::ParserError
        raise Error, "Evaluation collector returned invalid JSON; retain the report and run_id for retry"
      rescue IOError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
        raise Error, "Evaluation delivery failed (#{e.class}); retain the report and run_id for retry"
      end
    end
  end
end
