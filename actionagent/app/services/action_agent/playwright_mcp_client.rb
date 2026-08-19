# frozen_string_literal: true

module ActionAgent
  require "net/http"
  require "resolv"

  # Minimal MCP client (streamable HTTP transport) for a Playwright MCP
  # server — typically `npx @playwright/mcp --port 8931` running beside the
  # app in development, or a sandbox-provisioned browser container in
  # production. Speaks just enough JSON-RPC for tools/call: initialize once
  # per process, then call tools under the session id the server hands back.
  class PlaywrightMCPClient
    DEFAULT_URL = ENV.fetch("PLAYWRIGHT_MCP_URL", "http://host.orb.internal:8931/mcp")
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 60

    class Error < StandardError; end

    def self.instance
      @instance ||= new
    end

    def self.reset!
      @instance = nil
    end

    def initialize(url: DEFAULT_URL)
      @uri = URI(url)
      @mutex = Mutex.new
    end

    # Returns { text:, is_error: } — the tool result's text content.
    def call_tool(name, arguments = {})
      Rails.logger.debug("[PlaywrightMCPClient] call #{name} args=#{arguments.inspect[0, 200]}")
      ensure_session!
      response = post(
        { jsonrpc: "2.0", id: next_id, method: "tools/call",
          params: { name: name, arguments: arguments } },
        session: @session_id
      )
      result = response["result"]
      unless result
        Rails.logger.warn("[PlaywrightMCPClient] #{name} unexpected response: #{response.inspect[0, 500]}")
        raise Error, (response.dig("error", "message") || "empty MCP response")
      end

      text = Array(result["content"]).filter_map { |block| block["text"] }.join("\n")
      { text: text, is_error: result["isError"] ? true : false }
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Net::OpenTimeout, SocketError => e
      self.class.reset!
      raise Error, "Playwright MCP server unreachable at #{@uri} (#{e.class}): start it with `npx @playwright/mcp --port 8931`"
    end

    private

    def ensure_session!
      @mutex.synchronize do
        next if @session_id

        _body, response = post_raw(
          { jsonrpc: "2.0", id: next_id, method: "initialize",
            params: { protocolVersion: "2025-03-26", capabilities: {},
                      clientInfo: { name: "activeagents", version: "1.0" } } }
        )
        @session_id = response["mcp-session-id"]
        raise Error, "MCP server did not return a session id" unless @session_id

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
        "[PlaywrightMCPClient] #{payload[:method]} -> #{response.code} " \
        "ct=#{response['Content-Type']} bytes=#{response.body.to_s.bytesize} session=#{session ? 'yes' : 'no'}"
      )
      unless response.code.to_i.between?(200, 299)
        Rails.logger.warn("[PlaywrightMCPClient] HTTP #{response.code}: #{response.body.to_s[0, 300]}")
        raise Error, "MCP server returned HTTP #{response.code}"
      end

      parsed = parse_body(response)
      if parsed.empty? && payload[:id]
        Rails.logger.warn("[PlaywrightMCPClient] unparsed body (#{response['Content-Type']}): #{response.body.to_s[0, 500]}")
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
        JSON.parse(body)
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
