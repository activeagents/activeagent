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
    # immutable within the authenticated account once the report is complete.
    # Delivery is blocking and does not follow redirects with the account's
    # bearer credential. +verify!+ asks the collector whether it is up and
    # accepts the key before a run is paid for, and +progress+ shows a run's
    # results so far while it is still running.
    #
    # Every failure to deliver raises Error. Invalid arguments raise
    # ArgumentError before anything is sent.
    class Publisher
      DEFAULT_ENDPOINT = "https://api.activeagents.ai/v1/evaluations"
      # The hosted dashboard people sign in to; the hosted collector answers
      # on the API host, where a dashboard session does not reach.
      HOSTED_DASHBOARD_URL = "https://activeagents.ai"
      MAX_BYTES = 2 * 1024 * 1024
      DETAIL_LIMIT = 200

      # @return [String] the collector URL reports go to
      attr_reader :endpoint

      # @return [String] the address a receipt's "url" path resolves against: the
      #   dashboard_url given, or by default the endpoint's origin (its scheme,
      #   host and any non-default port, with no path), except that the hosted
      #   API host resolves to HOSTED_DASHBOARD_URL
      attr_reader :dashboard_url

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
      #
      # @param dashboard_url [String, nil] the address people open the dashboard at,
      #   where a receipt's "url" path resolves; by default the endpoint's origin,
      #   or HOSTED_DASHBOARD_URL for the hosted collector.
      #   The receipt's path, which carries the engine's mount, replaces any path on it
      # @raise [ArgumentError] "Evaluation dashboard_url is not an http(s) URL" when it is anything else, or
      #   "Evaluation dashboard_url must be an http(s) URL without credentials, query or fragment" when it carries one of those
      def initialize(api_key:, endpoint: DEFAULT_ENDPOINT, dashboard_url: nil, timeout: 10, open_timeout: 10)
        @uri = URI.parse(endpoint.to_s)
        unless @uri.is_a?(URI::HTTP) && @uri.host && !@uri.userinfo && !@uri.query && !@uri.fragment
          raise ArgumentError, "Evaluation endpoint must be an HTTP(S) URL without credentials, query or fragment"
        end
        unless @uri.scheme == "https" || %w[localhost 127.0.0.1 ::1].include?(@uri.hostname)
          raise ArgumentError, "Evaluation endpoint requires HTTPS except on loopback hosts"
        end
        @endpoint = @uri.to_s

        @dashboard_url = dashboard_url.nil? ? default_dashboard_url(@uri) : checked_dashboard_url(dashboard_url)

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

      # Returns a publisher built from +env+: ACTIVEAGENTS_API_KEY is the key,
      # ACTIVEAGENTS_EVALUATIONS_ENDPOINT the collector (DEFAULT_ENDPOINT when
      # blank) and ACTIVEAGENTS_DASHBOARD_URL the dashboard a receipt's "url"
      # path resolves against (the endpoint's origin when blank), so
      # publishing is one line:
      #
      #   Publisher.from_env.call(report: report, source: "support-app", agent_name: "SupportBot", suite: "support_desk")
      #
      # @param env [#[]] the environment to read, ENV by default
      # @raise [ArgumentError] "ACTIVEAGENTS_API_KEY is not set" for a blank key, and what +new+ raises for the other two
      # @return [Publisher]
      def self.from_env(env = ENV)
        api_key = env["ACTIVEAGENTS_API_KEY"].to_s.strip
        raise ArgumentError, "ACTIVEAGENTS_API_KEY is not set" if api_key.empty?

        endpoint = env["ACTIVEAGENTS_EVALUATIONS_ENDPOINT"].to_s.strip
        dashboard_url = env["ACTIVEAGENTS_DASHBOARD_URL"].to_s.strip
        new(api_key: api_key, endpoint: endpoint.empty? ? DEFAULT_ENDPOINT : endpoint, dashboard_url: dashboard_url.empty? ? nil : dashboard_url)
      end

      # Returns the collector's receipt for the completed +report+, a Report
      # or its saved JSON hash. Full prompts, answers and tool results are
      # included; applications should make publication opt-in.
      #
      # The receipt's "url" is the run's dashboard page, made absolute: a path
      # beginning with "/" is joined onto +dashboard_url+. An absolute URL, a
      # url that is neither (a relative reference without a leading slash, a
      # network-path reference, or a path that is not a valid URI) and a
      # receipt without one are left as the collector sent them.
      #
      # @param run_id [String, nil] the run's identity, kept across retries; by default
      #   the one the report's metadata records under "run_id" or :run_id, which
      #   Correlation#with_run puts there
      # @raise [ArgumentError] when no run_id is given and the report's metadata records none as a nonempty string
      def call(report:, run_id: nil, source:, agent_name:, suite:)
        run_id = resolve_run_id(report, run_id)
        envelope = self.class.envelope(report: report, run_id: run_id, source: source, agent_name: agent_name, suite: suite)
        publish(envelope, accepted: %w[complete], receipt: "completion receipt")
      end

      # Returns the collector's receipt for the results +report+ holds so far,
      # which the collector shows as a running run under +run_id+. Each call
      # replaces the results the previous one sent; +call+ with the finished
      # report under the same run_id completes the run. The receipt's status
      # is "running", or "complete" when the run already finished, and its
      # "url" is made absolute as +call+ makes it.
      #
      # Raises Error, without sending the report, when the collector does not
      # list "progress" among its capabilities (see +supports_progress?+): a
      # collector that predates progress would store the partial report as
      # complete.
      #
      # @param run_id [String, nil] as for +call+: by default the one the report's metadata records
      # @raise [ArgumentError] when no run_id is given and the report's metadata records none as a nonempty string
      def progress(report:, run_id: nil, source:, agent_name:, suite:)
        run_id = resolve_run_id(report, run_id)
        unless supports_progress?
          raise Error, "Evaluation collector does not accept progress; publish the finished report with call"
        end

        envelope = self.class.envelope(report: report, run_id: run_id, source: source, agent_name: agent_name, suite: suite, status: "running")
        publish(envelope, accepted: %w[running complete], receipt: "progress receipt")
      end

      # Returns true when the collector accepts +progress+. Asks it once, with
      # the probe +verify!+ sends, unless +verify!+ already has; raises as
      # +verify!+ does.
      def supports_progress?
        verify! if @capabilities.nil?
        @capabilities.include?("progress")
      end

      # Returns true when the collector is up and accepts the API key, without
      # storing anything. It posts an empty JSON object, which a compatible
      # collector authenticates, parses, and then refuses with a 422 whose
      # +error+ names +version+, as not a version-1 report. That refusal, and
      # only that one, is the ready answer. Call it before an expensive run, so
      # a stopped collector or a refused key fails before the first model call
      # rather than after the last one.
      #
      # The refusal's +capabilities+ is what +supports_progress?+ reads.
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
            if detail&.match?(/\bversion\b/)
              @capabilities = collector_capabilities(response.body)
              next true
            end

            raise Error.new("Evaluation collector answered HTTP 422 without refusing the empty envelope as a version-1 report, " \
                            "so it is not a compatible collector; check the endpoint", status: 422, detail: detail)
          end
          raise rejection(response) unless %w[200 201].include?(response.code)

          raise Error, "Evaluation collector stored an empty report, so it is not a compatible collector; check the endpoint"
        end
      end

      # The version-1 envelope a collector stores: the four identities, the
      # version and the report's hash. What #call sends, and what a
      # collector's export of a stored run returns, so the export can be
      # posted again. report may be a Report or its saved JSON hash.
      #
      # `status: "running"` marks the envelope +progress+ sends; a complete
      # report's envelope carries no status.
      #
      # Raises ArgumentError for an identity that is not a nonempty string,
      # or a report that is neither.
      def self.envelope(report:, run_id:, source:, agent_name:, suite:, status: nil)
        identities = { "run_id" => run_id, "source" => source, "agent_name" => agent_name, "suite" => suite }
        identities.each do |key, value|
          raise ArgumentError, "#{key} must be a nonempty string" unless value.is_a?(String) && !value.strip.empty?
        end
        hash = report.to_h if report.respond_to?(:to_h) && !report.nil? && !report.is_a?(Array)
        raise ArgumentError, "report must be a Report or its saved JSON hash" unless hash.is_a?(Hash)

        envelope = identities.merge("version" => 1, "report" => hash)
        status ? envelope.merge("status" => status) : envelope
      end

      private

      # The run_id a delivery goes under: +run_id+ when given, otherwise the
      # one the report's metadata records under a String or Symbol key, which
      # Correlation#with_run puts there. Raises ArgumentError for a report
      # that is neither a Report nor a hash, as +envelope+ does, and when
      # neither +run_id+ nor the metadata names a nonempty string.
      def resolve_run_id(report, run_id)
        return run_id unless run_id.nil?

        hash = report.to_h if report.respond_to?(:to_h) && !report.nil? && !report.is_a?(Array)
        raise ArgumentError, "report must be a Report or its saved JSON hash" unless hash.is_a?(Hash)

        metadata = hash["metadata"]
        recorded = metadata["run_id"] || metadata[:run_id] if metadata.is_a?(Hash)
        return recorded if recorded.is_a?(String) && !recorded.strip.empty?

        raise ArgumentError, "run_id must be given, or the report's metadata must carry one (Correlation#with_run records it)"
      end

      # The hosted collector's API host serves no dashboard session, so its
      # receipts resolve against the hosted dashboard; any other collector is
      # its own dashboard.
      def default_dashboard_url(uri)
        uri.hostname == URI.parse(DEFAULT_ENDPOINT).hostname ? HOSTED_DASHBOARD_URL : origin(uri)
      end

      # Returns the dashboard_url given as a String, raising ArgumentError
      # unless it is an http(s) URL with a host and without credentials, a
      # query or a fragment.
      def checked_dashboard_url(value)
        uri = URI.parse(value.to_s)
        raise ArgumentError, "Evaluation dashboard_url is not an http(s) URL" unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
        if uri.userinfo || uri.query || uri.fragment
          raise ArgumentError, "Evaluation dashboard_url must be an http(s) URL without credentials, query or fragment"
        end

        value.to_s
      rescue URI::InvalidURIError
        raise ArgumentError, "Evaluation dashboard_url is not an http(s) URL"
      end

      # The origin of +uri+: its scheme, host and any non-default port, with no path.
      def origin(uri)
        uri.dup.tap { |without_path| without_path.path = "" }.to_s
      end

      # Delivers +envelope+ and returns the collector's receipt, which must name
      # the envelope's run_id, a stored run, and one of the +accepted+ statuses,
      # with a "url" path made absolute on the dashboard.
      def publish(envelope, accepted:, receipt:)
        body = encode(envelope)
        raise Error, "Evaluation report exceeds the 2 MiB delivery limit; publish a smaller selection" if body.bytesize > MAX_BYTES

        deliver("retain the report and run_id for retry") do
          response = post(body)
          raise rejection(response) unless %w[200 201].include?(response.code)

          answer = JSON.parse(response.body.to_s)
          unless answer.is_a?(Hash) && answer["run_id"] == envelope["run_id"] && accepted.include?(answer["status"]) &&
                 answer["id"] && answer["evaluation_id"]
            raise Error.new("Evaluation collector returned an invalid #{receipt}; retain the report and run_id for retry", retryable: true)
          end
          resolve_url(answer)
        end
      end

      # Returns +receipt+ with a "url" that is a path beginning with "/" joined
      # onto +dashboard_url+. Any other url (an absolute one, a relative
      # reference without a leading slash, a network-path reference, a path
      # that is not a valid URI) and a receipt without one are left as the
      # collector sent them.
      def resolve_url(receipt)
        url = receipt["url"]
        return receipt unless url.is_a?(String) && url.start_with?("/") && !url.start_with?("//")

        receipt.merge("url" => URI.join(@dashboard_url, url).to_s)
      rescue URI::InvalidURIError
        receipt
      end

      # The string entries of a JSON object body's +capabilities+ array, or none.
      def collector_capabilities(body)
        parsed = JSON.parse(body.to_s)
        list = parsed["capabilities"] if parsed.is_a?(Hash)
        list.is_a?(Array) ? list.grep(String).freeze : [].freeze
      rescue JSON::ParserError, EncodingError
        [].freeze
      end

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
