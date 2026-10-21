# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require "zlib"
require_relative "../evals/publisher"

module ActiveAgent
  class CLI
    # HTTP to one dashboard mount, with the conventions of
    # ActiveAgent::Evals::Publisher: blocking, bounded timeouts, no redirects
    # followed with a bearer key, and errors that never quote a response body
    # beyond its sanitized +error+ string, with the keys filtered out.
    #
    # The dashboard authenticates two kinds of key, and this client sends
    # each where it belongs:
    #
    # - +api_key+, a dashboard API key (Settings -> API Keys, "aa_..."), for
    #   the MCP facade at <mount>/mcp, whose dashboard tools back most
    #   commands.
    # - +ingest_key+, the install's ingest key (ActionAgent.ingest_api_key,
    #   or the tenant's telemetry key), for the collector endpoints under
    #   <mount>/api/evaluation_reports. Defaults to +api_key+.
    class Client
      DETAIL_LIMIT = 200
      JSONRPC_INVALID_PARAMS = -32602

      attr_reader :url

      def initialize(url:, api_key: nil, ingest_key: nil, timeout: 30, open_timeout: 10)
        @uri = self.class.parse_url(url)
        @url = @uri.to_s
        @api_key = api_key.to_s.strip
        @ingest_key = ingest_key.to_s.strip.empty? ? @api_key : ingest_key.to_s.strip
        @timeout = timeout
        @open_timeout = open_timeout
        @request_id = 0
      end

      # The dashboard mount as a URI, without a trailing slash. HTTPS is
      # required except on loopback hosts, as for the publisher.
      def self.parse_url(url)
        uri = URI.parse(url.to_s.strip.sub(%r{/+\z}, ""))
        unless uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
          raise Error.new("The dashboard URL must be an HTTP(S) URL without credentials, query or fragment, " \
                          "such as https://ops.example.com/activeagents", exit_code: EXIT_USAGE)
        end
        unless uri.scheme == "https" || %w[localhost 127.0.0.1 ::1].include?(uri.hostname)
          raise Error.new("The dashboard URL requires HTTPS except on loopback hosts", exit_code: EXIT_USAGE)
        end
        uri
      rescue URI::InvalidURIError
        raise Error.new("The dashboard URL is not a valid URL", exit_code: EXIT_USAGE)
      end

      def mcp_endpoint
        "#{url}/mcp"
      end

      def reports_endpoint
        "#{url}/api/evaluation_reports"
      end

      # A Publisher for the mount's collector, authenticated with the ingest key.
      def publisher
        require_key!(@ingest_key, "an ingest key")
        ActiveAgent::Evals::Publisher.new(api_key: @ingest_key, endpoint: reports_endpoint, timeout: @timeout, open_timeout: @open_timeout)
      rescue ArgumentError => e
        raise Error.new(e.message, exit_code: EXIT_CONFIG)
      end

      # Sends one JSON-RPC request to the MCP facade and returns its result.
      def mcp(method, params = {})
        require_key!(@api_key, "a dashboard API key")
        @request_id += 1
        body = JSON.generate(jsonrpc: "2.0", id: @request_id, method: method, params: params)
        response = exchange(:post, URI(mcp_endpoint), @api_key, body: body)

        case response.code
        when "200" then nil
        when "401" then raise refused("the dashboard refused the API key; create one under Settings -> API Keys", response, @api_key, 401)
        when "404" then raise refused("nothing at #{mcp_endpoint} answers MCP; check the dashboard URL (the engine's mount)", response, @api_key, 404)
        else raise refused("the dashboard's MCP endpoint answered HTTP #{response.code}", response, @api_key, response.code.to_i)
        end

        payload = parse_json(response.body)
        if (error = payload["error"])
          raise Error.new("#{method} failed: #{sanitize(error["message"], @api_key) || "error #{error["code"]}"}", status: error["code"])
        end
        payload["result"]
      end

      # Calls one of the dashboard's MCP tools and returns its structured
      # result. A tool's own refusal (isError) raises with its message; a
      # dashboard tool the facade does not list means the install turned
      # them off (ActionAgent.mcp_dashboard_tools = false) or predates them.
      def tool(name, arguments = {})
        result = mcp("tools/call", name: name, arguments: arguments.compact)
        structured = result.is_a?(Hash) ? result["structuredContent"] : nil
        if result.is_a?(Hash) && result["isError"]
          message = structured.is_a?(Hash) && structured["error"] || Array(result["content"]).filter_map { |part| part["text"] if part.is_a?(Hash) }.join(" ")
          raise Error.new("#{name}: #{sanitize(message, @api_key) || "the tool refused the call"}")
        end
        structured.is_a?(Hash) ? structured : {}
      rescue Error => e
        raise unless e.status == JSONRPC_INVALID_PARAMS && e.message.include?("Unknown tool")

        raise Error.new("This dashboard does not offer the #{name} tool over MCP: it predates the dashboard tools, or " \
                        "the install sets ActionAgent.mcp_dashboard_tools = false", exit_code: EXIT_UNAVAILABLE)
      end

      # GETs +path+ under the mount with the ingest key and returns the
      # response, raising on anything but 200.
      def get(path, accept:, query: nil, not_found: nil)
        require_key!(@ingest_key, "an ingest key")
        uri = URI("#{url}#{path}")
        uri.query = query if query
        response = exchange(:get, uri, @ingest_key, accept: accept)
        return response if response.code == "200"

        if response.code == "404" && not_found
          raise refused(not_found, response, @ingest_key, 404, exit_code: EXIT_UNAVAILABLE)
        end
        if response.code == "401"
          raise refused("the dashboard refused the ingest key; use the mount's ingest_api_key (--ingest-key)", response, @ingest_key, 401)
        end
        raise refused("GET #{path} answered HTTP #{response.code}", response, @ingest_key, response.code.to_i)
      end

      private

      def require_key!(key, label)
        return unless key.empty?

        raise Error.new("No #{label}: run `activeagent login`, or set ACTIVEAGENT_API_KEY", exit_code: EXIT_CONFIG)
      end

      def exchange(verb, uri, key, body: nil, accept: "application/json")
        http = Net::HTTP.new(uri.hostname, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @timeout
        http.write_timeout = @timeout
        request = (verb == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri.request_uri)
        request["Authorization"] = "Bearer #{key}"
        request["Accept"] = accept
        request["User-Agent"] = "activeagent-cli/#{ActiveAgent::CLI.version}"
        if body
          request["Content-Type"] = "application/json"
          request.body = body
        end
        http.request(request)
      rescue Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::Error => e
        # These messages can quote the response's status line, headers or body.
        raise Error.new("The dashboard returned a malformed response (#{e.class})"), cause: nil
      rescue IOError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
        raise Error.new("Could not reach #{uri.scheme}://#{uri.host} (#{e.class}); check the URL and that the dashboard is up")
      end

      def parse_json(body)
        parsed = JSON.parse(body.to_s)
        raise Error, "The dashboard returned JSON that is not an object" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError
        # The parser's message quotes the body.
        raise Error.new("The dashboard returned invalid JSON"), cause: nil
      end

      def refused(message, response, key, status, exit_code: EXIT_FAILURE)
        detail = begin
          parsed = JSON.parse(response.body.to_s)
          sanitize(parsed["error"], key) if parsed.is_a?(Hash)
        rescue JSON::ParserError, EncodingError
          nil
        end
        Error.new(detail ? "#{message} (#{detail})" : message, status: status, exit_code: exit_code)
      end

      # Control characters and runs of whitespace become one space, the keys
      # become [FILTERED], and the result is cut to DETAIL_LIMIT characters.
      def sanitize(message, key)
        return unless message.is_a?(String)

        detail = message.scrub.gsub(/[[:space:]\p{C}]+/, " ").strip
        [ key, @api_key, @ingest_key ].uniq.reject(&:empty?).each { |secret| detail = detail.gsub(secret, "[FILTERED]") }
        return if detail.empty?

        detail.length > DETAIL_LIMIT ? "#{detail[0, DETAIL_LIMIT - 1].rstrip}…" : detail
      end
    end
  end
end
