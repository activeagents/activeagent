# frozen_string_literal: true

require "net/http"
require "resolv"
require "uri"
require "json"

module ActionAgent
  # Speaks Streamable HTTP MCP: initialize once per client, then call tools
  # under the session id the server hands back. One instance per server url.
  #
  # A server answers as plain JSON or as an SSE stream whose data: lines carry
  # the JSON-RPC response; both are accepted.
  class MCPClient
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 60

    class Error < StandardError; end

    def initialize(url:, label: nil)
      @uri = URI(url)
      @label = label.presence || @uri.host
      @mutex = Mutex.new
    end

    # The server's own tool definitions, as the provider expects them:
    # { name:, description:, parameters: }. An MCP server describes its tools
    # in tools/list, so the model is told about them in the server's words
    # rather than a copy kept in the dashboard.
    def list_tools
      ensure_session!
      response = post({ jsonrpc: "2.0", id: next_id, method: "tools/list", params: {} }, session: @session_id)
      Array(response.dig("result", "tools")).map do |tool|
        {
          name: tool["name"],
          description: tool["description"].to_s,
          parameters: tool["inputSchema"] || { type: "object", properties: {} }
        }
      end
    end

    # Returns { text:, is_error: } — the tool result's text content.
    def call_tool(name, arguments = {})
      Rails.logger.debug("[MCPClient] call #{name} args=#{arguments.inspect[0, 200]}")
      ensure_session!
      response = post(
        { jsonrpc: "2.0", id: next_id, method: "tools/call",
          params: { name: name, arguments: arguments } },
        session: @session_id
      )
      result = response["result"]
      unless result
        Rails.logger.warn("[MCPClient] #{name} unexpected response: #{response.inspect[0, 500]}")
        raise Error, (response.dig("error", "message") || "empty MCP response")
      end

      text = Array(result["content"]).filter_map { |block| block["text"] }.join("\n")
      { text: text, is_error: result["isError"] ? true : false }
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Net::OpenTimeout, SocketError => e
      raise Error, "MCP server #{@label} unreachable at #{@uri} (#{e.class})"
    end

    private

    # Opens the session once. A server that keeps per-session state answers
    # initialize with an Mcp-Session-Id and expects it on every later request;
    # a stateless server (the shape a multi-worker Rails host serves) returns
    # none, and later requests carry no session header. Both are the protocol's
    # own contract, so an absent id is not an error — @initialized records that
    # the handshake happened either way.
    def ensure_session!
      @mutex.synchronize do
        next if @initialized

        _body, response = post_raw(
          { jsonrpc: "2.0", id: next_id, method: "initialize",
            params: { protocolVersion: "2025-03-26", capabilities: {},
                      clientInfo: { name: "activeagents", version: "1.0" } } }
        )
        @session_id = response["mcp-session-id"].presence
        @initialized = true

        post({ jsonrpc: "2.0", method: "notifications/initialized" }, session: @session_id)
      end
    end

    def post(payload, session: nil)
      body, _response = post_raw(payload, session: session)
      body
    end

    def post_raw(payload, session: nil)
      # Tool calls run inside the provider SDK's streaming enumerator — a
      # fiber, where Net::HTTP reads of SSE bodies misbehave (headers arrive,
      # body comes back empty). A dedicated thread always does real blocking
      # IO outside any fiber/scheduler context.
      Thread.new { blocking_post_raw(payload, session: session) }.value
    end

    def blocking_post_raw(payload, session: nil)
      http = Net::HTTP.new(@uri.host, @uri.port)
      # Container->host bridge hostnames (host.orb.internal) publish an IPv6
      # address whose path doesn't reach the server; dual-stack connects then
      # fail intermittently. Pin to IPv4 while keeping the Host header.
      if (ipv4 = ipv4_address)
        http.ipaddr = ipv4
      end
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS
      request = Net::HTTP::Post.new(@uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json, text/event-stream"
      request["Mcp-Session-Id"] = session if session
      request.body = payload.to_json

      response = http.request(request)
      Rails.logger.debug(
        "[MCPClient] #{payload[:method]} -> #{response.code} " \
        "ct=#{response['Content-Type']} bytes=#{response.body.to_s.bytesize} session=#{session ? 'yes' : 'no'}"
      )
      unless response.code.to_i.between?(200, 299)
        Rails.logger.warn("[MCPClient] HTTP #{response.code}: #{response.body.to_s[0, 300]}")
        raise Error, "MCP server returned HTTP #{response.code}"
      end

      parsed = parse_body(response)
      if parsed.empty? && payload[:id]
        Rails.logger.warn("[MCPClient] unparsed body (#{response['Content-Type']}): #{response.body.to_s[0, 500]}")
      end
      [ parsed, response ]
    end

    # Streamable HTTP answers as plain JSON or as an SSE stream whose data:
    # lines carry the JSON-RPC response — accept both.
    def parse_body(response)
      body = response.body.to_s
      return {} if body.empty?

      if response["Content-Type"].to_s.include?("text/event-stream")
        body.lines
            .select { |line| line.start_with?("data:") }
            .filter_map { |line| JSON.parse(line.delete_prefix("data:").strip) rescue nil }
            .find { |json| json["result"] || json["error"] } || {}
      else
        # A notification carries no id, and a server may answer it with a bare
        # `null` body — JSON, but not an object.
        JSON.parse(body) || {}
      end
    rescue JSON::ParserError
      {}
    end

    def ipv4_address
      return @ipv4_address if defined?(@ipv4_address)

      @ipv4_address = Resolv.getaddresses(@uri.host).find { |address| address =~ Resolv::IPv4::Regex }
    rescue Resolv::ResolvError
      @ipv4_address = nil
    end

    def next_id
      @id = (@id || 0) + 1
    end
  end
end
