# frozen_string_literal: true

require "json"
require "net/http"
require "resolv"

module ActionAgent
  # A tool client for MCP's Streamable HTTP transport. A server may return
  # JSON or SSE, and may use a session id or operate without sessions.
  class MCPClient
    PROTOCOL_VERSION = "2025-06-18"
    SUPPORTED_PROTOCOL_VERSIONS = [ PROTOCOL_VERSION, "2025-03-26" ].freeze
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 60

    class Error < StandardError; end
    class SessionExpired < Error; end

    def initialize(url:, transport: "http")
      transport = "http" if transport.nil? || transport.to_s.empty?
      unless %w[http streamable_http streamable-http].include?(transport.to_s.downcase)
        raise Error, "Unsupported MCP transport #{transport.inspect}; use Streamable HTTP (http). stdio and legacy SSE are not supported"
      end

      @uri = URI.parse(url.to_s)
      unless @uri.is_a?(URI::HTTP) && @uri.host
        raise Error, "MCP server URL must be an absolute HTTP or HTTPS URL"
      end
      @session_mutex = Mutex.new
      @id_mutex = Mutex.new
    rescue URI::InvalidURIError
      raise Error, "MCP server URL must be an absolute HTTP or HTTPS URL"
    end

    # Return the server's tool definitions, preserving inputSchema and any
    # optional metadata. Follow cursors because tools/list can be paginated.
    def list_tools
      tools = []
      cursors = []
      cursor = nil
      loop do
        result = request("tools/list", cursor ? { cursor: cursor } : {})
        unless result["tools"].is_a?(Array) && result["tools"].all? { |tool| tool.is_a?(Hash) }
          raise Error, "MCP tools/list response must contain a tools array"
        end
        tools.concat(result["tools"])
        cursor = result["nextCursor"]
        break if cursor.nil?
        raise Error, "MCP tools/list returned an invalid or repeated cursor" unless cursor.is_a?(String) && !cursors.include?(cursor)

        cursors << cursor
      end
      tools
    end

    # Keep the browser client's existing result contract. Structured output
    # is retained too, including servers that return no text blocks.
    def call_tool(name, arguments = {})
      result = request("tools/call", { name: name, arguments: arguments })
      text = Array(result["content"]).filter_map { |block| block["text"] if block.is_a?(Hash) }.join("\n")
      output = { text: text, is_error: result["isError"] == true }
      if result.key?("structuredContent")
        output[:structured_content] = result["structuredContent"]
        output[:text] = JSON.generate(result["structuredContent"]) if text.empty?
      end
      output
    end

    private

    def request(method, params)
      retries = 0
      begin
        ensure_session!
        body, = post_raw(
          { jsonrpc: "2.0", id: next_id, method: method, params: params },
          session: @session_id, protocol_version: @protocol_version
        )
        result_from(body)
      rescue SessionExpired
        reset_session!
        raise if retries >= 1

        retries += 1
        retry
      rescue SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => e
        reset_session!
        raise Error, "MCP server connection failed (#{e.class})"
      end
    end

    def ensure_session!
      @session_mutex.synchronize do
        return if @initialized

        body, response = post_raw(
          { jsonrpc: "2.0", id: next_id, method: "initialize",
            params: { protocolVersion: PROTOCOL_VERSION, capabilities: {},
                      clientInfo: { name: "activeagents", version: "1.0" } } }
        )
        protocol_version = result_from(body)["protocolVersion"]
        unless SUPPORTED_PROTOCOL_VERSIONS.include?(protocol_version)
          raise Error, "Unsupported MCP protocol version #{protocol_version.inspect}"
        end
        session_id = response["mcp-session-id"]
        post_raw(
          { jsonrpc: "2.0", method: "notifications/initialized" },
          session: session_id, protocol_version: protocol_version
        )
        @session_id = session_id
        @protocol_version = protocol_version
        @initialized = true
      end
    end

    def reset_session!
      @session_mutex.synchronize do
        @initialized = false
        @session_id = nil
        @protocol_version = nil
      end
    end

    def result_from(body)
      if body["error"]
        error = body["error"]
        raise Error, "MCP error #{error['code']}: #{error['message']}"
      end
      raise Error, "MCP response is missing a result" unless body["result"].is_a?(Hash)

      body["result"]
    end

    def post_raw(payload, session: nil, protocol_version: nil)
      # Provider SDK streaming enumerators run in fibers. Keep Net::HTTP's
      # blocking reads on a dedicated thread, as the browser client did.
      Thread.new do
        Thread.current.report_on_exception = false
        blocking_post_raw(payload, session: session, protocol_version: protocol_version)
      end.value
    end

    def blocking_post_raw(payload, session:, protocol_version:)
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = @uri.scheme == "https"
      # Container->host bridge hostnames can publish an unreachable IPv6
      # address. Pin to IPv4 where available, retaining Host and TLS SNI.
      http.ipaddr = ipv4_address if ipv4_address
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS
      request = Net::HTTP::Post.new(@uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json, text/event-stream"
      request["Mcp-Session-Id"] = session if session
      request["MCP-Protocol-Version"] = protocol_version if protocol_version
      request.body = JSON.generate(payload)

      http.request(request) do |response|
        raise SessionExpired, "MCP session expired" if response.code == "404" && session
        unless response.code.to_i.between?(200, 299)
          raise Error, "MCP server returned HTTP #{response.code}"
        end

        return [ {}, response ] unless payload.key?(:id)

        return [ parse_body(response, payload[:id]), response ]
      end
    end

    def parse_body(response, request_id)
      if response["Content-Type"].to_s.include?("text/event-stream")
        # SSE data may span multiple lines and network chunks. Stop when
        # our response arrives; the server need not close the stream first.
        buffer = +""
        response.read_body do |chunk|
          buffer << chunk
          while (boundary = /\r?\n\r?\n/.match(buffer))
            event = buffer.slice!(0, boundary.end(0))
            data = event.lines.filter_map do |line|
              line.delete_prefix("data:").delete_prefix(" ").chomp if line.start_with?("data:")
            end.join("\n")
            next if data.empty?

            parsed = JSON.parse(data)
            return parsed if matching_response?(parsed, request_id)
          end
        end
      else
        parsed = JSON.parse(response.body.to_s)
        return parsed if matching_response?(parsed, request_id)
      end
      raise Error, "MCP server did not return a response for request #{request_id}"
    rescue JSON::ParserError
      raise Error, "MCP server returned invalid JSON"
    end

    def matching_response?(body, request_id)
      body.is_a?(Hash) && body["jsonrpc"] == "2.0" && body["id"] == request_id &&
        (body.key?("result") || body.key?("error"))
    end

    def ipv4_address
      return @ipv4_address if defined?(@ipv4_address)

      @ipv4_address = Resolv.getaddresses(@uri.host).find { |address| address =~ Resolv::IPv4::Regex }
    rescue Resolv::ResolvError
      @ipv4_address = nil
    end

    def next_id
      @id_mutex.synchronize { @id = (@id || 0) + 1 }
    end
  end
end
