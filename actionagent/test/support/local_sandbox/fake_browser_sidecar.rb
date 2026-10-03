# frozen_string_literal: true

# A stand-in for Node running the browser sidecar, run by LocalBrowserTest as
# ActionAgent.node_command. It answers the way BrowserSidecar and
# LocalSandboxBackend call `node`:
#
#   fake_browser_sidecar.rb [flags] --version            the Node version
#   fake_browser_sidecar.rb [flags] <entrypoint> check   the sidecar's report
#   fake_browser_sidecar.rb [flags] <entrypoint> serve   the sidecar
#
# Flags (set by the test's wrapper script):
#   --sidecar-version=X   the version check and serve report
#   --no-chromium         check reports Chromium missing
#   --exit-early          serve prints to stderr and exits before it is ready
#
# serve reads the configuration from stdin, writes it with its argv, its
# environment and its pids to record.json in the configured workdir, starts a
# `sleep` in its process group, prints the ready line and answers MCP
# requests that carry the configured token. Plain Ruby and the standard
# library only, like the other sandbox fixtures.
require "json"
require "socket"

$stdout.sync = true
flags, args = ARGV.partition { |arg| arg.start_with?("--") && arg != "--version" }
option = ->(name) { flags.find { |flag| flag.start_with?("--#{name}=") }&.split("=", 2)&.last }
version = option.call("sidecar-version") || abort("fake sidecar: --sidecar-version is required")

if args == [ "--version" ]
  puts "v20.11.1"
  exit 0
end

_entrypoint, command = args
case command
when "check"
  puts JSON.generate("version" => version, "node" => "v20.11.1",
    "chromium" => { "installed" => !flags.include?("--no-chromium"), "executable" => "/fake/chromium" })
  exit 0
when "serve"
  nil
else
  warn "fake sidecar: unknown command #{args.inspect}"
  exit 2
end

config = JSON.parse($stdin.read)
if flags.include?("--exit-early")
  warn "fake sidecar: refusing to start with token #{config["token"]}"
  exit 1
end

child = Process.spawn("sleep", "600")
server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
File.write(File.join(config.fetch("workdir"), "record.json"), JSON.generate(
  "config" => config, "argv" => ARGV, "env" => ENV.to_h, "pid" => Process.pid, "pgid" => Process.getpgrp,
  "child_pid" => child, "cwd" => Dir.pwd
))
trap("TERM") { exit 0 }

puts JSON.generate("ready" => true, "port" => port, "version" => version, "pid" => Process.pid)

def respond(client, status, body, headers = {})
  head = [ "HTTP/1.1 #{status} #{status == 200 ? "OK" : "Error"}", "Content-Type: application/json",
           "Content-Length: #{body.bytesize}", "Connection: close", *headers.map { |name, value| "#{name}: #{value}" } ]
  client.write("#{head.join("\r\n")}\r\n\r\n#{body}")
end

TOOLS = %w[browser_navigate browser_snapshot browser_click].map do |name|
  { "name" => name, "description" => "#{name} in the sandbox's browser", "inputSchema" => { "type" => "object" } }
end

loop do
  client = server.accept
  begin
    client.gets
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.strip.downcase] = value.to_s.strip
    end
    body = client.read(headers["content-length"].to_i)

    if headers["authorization"] != "Bearer #{config["token"]}"
      respond(client, 401, JSON.generate("error" => "Missing or invalid bearer token"))
      next
    end

    rpc = JSON.parse(body)
    result =
      case rpc["method"]
      when "initialize" then { "protocolVersion" => "2025-03-26", "capabilities" => { "tools" => {} } }
      when "tools/list" then { "tools" => TOOLS }
      when "tools/call"
        { "content" => [ { "type" => "text", "text" => "#{rpc.dig("params", "name")} #{rpc.dig("params", "arguments").to_json}" } ] }
      end
    if rpc.key?("id")
      respond(client, 200, JSON.generate("jsonrpc" => "2.0", "id" => rpc["id"], "result" => result), "Mcp-Session-Id" => "fake-session")
    else
      respond(client, 202, "")
    end
  rescue StandardError => e
    warn "fake sidecar: #{e.class}: #{e.message}"
  ensure
    client.close
  end
end
