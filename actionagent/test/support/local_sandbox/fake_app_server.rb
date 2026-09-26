# frozen_string_literal: true

# A stand-in for a checkout's app server, run by LocalSandboxBackendTest as
# sandbox.yml's `start`. Plain Ruby and the standard library only: sandbox
# processes run without the dashboard's bundle.
#
#   ruby fake_app_server.rb [serve|stubborn|hang] [record_path]
#
# serve     answers the manifest's MCP path the way the engine's facade does:
#           405 to a GET, and JSON-RPC to a POST that carries the manifest's
#           bearer token (401 without it).
# stubborn  serves, but ignores SIGTERM: only SIGKILL stops it.
# hang      never listens, so the boot times out.
#
# Either way it first starts a `sleep` in its own process group, so a test can
# show that stopping the sandbox stops the whole group, and writes its pids and
# its environment to record_path (tmp/server.json in the checkout by default).
require "json"
require "socket"

$stdout.sync = true
mode = ARGV[0] || "serve"
record = ARGV[1] || File.join("tmp", "server.json")

child = Process.spawn("sleep", "600")
Dir.mkdir(File.dirname(record)) unless Dir.exist?(File.dirname(record))
File.write(record, JSON.generate(
  "pid" => Process.pid, "pgid" => Process.getpgrp, "child_pid" => child, "env" => ENV.to_h
))

trap("TERM") { puts "fake app server: ignoring SIGTERM" } if mode == "stubborn"

if mode == "hang"
  puts "fake app server: booting forever"
  sleep
end

manifest = JSON.parse(File.read(ENV.fetch("ACTION_AGENT_SANDBOX_MANIFEST")))
server = TCPServer.new("127.0.0.1", Integer(ENV.fetch("PORT")))
puts "fake app server: listening on 127.0.0.1:#{ENV.fetch("PORT")}"

REASONS = { 200 => "OK", 401 => "Unauthorized", 404 => "Not Found", 405 => "Method Not Allowed" }.freeze

def respond(client, status, body, headers = {})
  head = [
    "HTTP/1.1 #{status} #{REASONS.fetch(status)}",
    "Content-Type: application/json",
    "Content-Length: #{body.bytesize}",
    "Connection: close",
    *headers.map { |name, value| "#{name}: #{value}" }
  ]
  client.write("#{head.join("\r\n")}\r\n\r\n#{body}")
end

def rpc_result(rpc)
  case rpc["method"]
  when "initialize"
    { "protocolVersion" => "2025-03-26", "serverInfo" => { "name" => "fake-app" }, "capabilities" => { "tools" => {} } }
  when "tools/list"
    { "tools" => [ { "name" => "fixture_tool", "description" => "A tool the checkout serves", "inputSchema" => { "type" => "object" } } ] }
  else
    {}
  end
end

loop do
  client = server.accept
  begin
    verb, path = client.gets.to_s.split
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.strip.downcase] = value.to_s.strip
    end
    body = client.read(headers["content-length"].to_i)

    if path != manifest["mcp_path"]
      respond(client, 404, "{}")
    elsif verb == "GET"
      respond(client, 405, JSON.generate("error" => "POST JSON-RPC here"), "Allow" => "POST")
    elsif headers["authorization"] != "Bearer #{manifest["mcp_token"]}"
      respond(client, 401, JSON.generate("error" => "unauthorized"))
    else
      rpc = JSON.parse(body)
      respond(client, 200, JSON.generate("jsonrpc" => "2.0", "id" => rpc["id"], "result" => rpc_result(rpc)))
    end
  rescue StandardError => e
    puts "fake app server: #{e.class}: #{e.message}"
  ensure
    client.close
  end
end
