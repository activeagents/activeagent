# frozen_string_literal: true

# A stdio MCP server for the bridge's read timeout tests.
#
#   ruby stalling_mcp_server.rb PID_FILE [METHOD [silent]]
#
# It answers like any server, except that it never answers a request for
# METHOD. In its place it sends progress notifications and pings for as long as
# it runs or, given `silent`, sends nothing at all. It writes its pid to
# PID_FILE, so a test can tell whether the process outlived the bridge, and it
# exits when its stdin closes.

require "json"

pid_file, stalled_method, mode = ARGV
File.write(pid_file, Process.pid.to_s)

$stdout.sync = true
OUTPUT = Mutex.new

def send_message(message)
  OUTPUT.synchronize { $stdout.puts(JSON.generate({ jsonrpc: "2.0" }.merge(message))) }
end

# Talks without ever answering, as a server reporting progress on a request it
# never completes would.
def chatter
  Thread.new do
    1.step do |count|
      send_message(method: "notifications/progress", params: { progressToken: "stalled", progress: count })
      send_message(id: "ping-#{count}", method: "ping") if (count % 5).zero?
      sleep 0.05
    end
  rescue IOError, SystemCallError
    # The client has closed the connection.
  end
end

$stdin.each_line do |line|
  request = JSON.parse(line)
  # Notifications, and the client's answers to pings, take no reply.
  next unless request["method"] && request.key?("id")

  if request["method"] == stalled_method
    chatter unless mode == "silent"
    next
  end

  case request["method"]
  when "initialize"
    send_message(id: request["id"], result: { protocolVersion: request.dig("params", "protocolVersion"),
                                              capabilities:    { tools: {} },
                                              serverInfo:      { name: "stalling", version: "1.0.0" } })
  when "tools/list"
    send_message(id: request["id"], result: { tools: [ { name: "wait", inputSchema: { type: "object", properties: {} } } ] })
  when "tools/call"
    send_message(id: request["id"], result: { content: [ { type: "text", text: "done" } ] })
  else
    send_message(id: request["id"], error: { code: -32_601, message: "Method not found: #{request["method"]}" })
  end
end
