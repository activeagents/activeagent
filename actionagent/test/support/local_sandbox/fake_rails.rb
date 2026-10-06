# frozen_string_literal: true

# A stand-in for a checkout's bin/rails in LocalSandboxBackendTest's bootstrap
# boots, run by the fixture's bin/rails wrapper. Plain Ruby and the standard
# library only.
#
# Appends each invocation to $FAKE_TOOLS_LOG, then does what the real command
# would leave behind:
#
#   -T -A                           lists db:prepare, the manifest task and
#                                   whatever "tasks" $FAKE_CONTROL names
#   generate active_agent:install   writes config/active_agent.yml and
#                                   app/agents/application_agent.rb, unless
#                                   they exist (as --skip does)
#   generate action_agent:install   writes the initializer and a migration,
#                                   and mounts the engine
#   db:prepare                      writes db/schema.rb
#   action_agent:sandbox:manifest   writes the runtime manifest
#   server ...                      runs fake_app_server.rb
#   anything else                   does nothing
#
# $FAKE_CONTROL names a JSON file:
#
#   "fail"        commands (the first word after bin/rails) that exit 1
#   "sleep"       commands that hang instead
#   "tasks"       extra task names -T -A lists
#   "echo"        a variable whose value db:prepare prints, before it fails
#                 or does anything else
#   "root_status" the status the server answers GET / with
require "fileutils"
require "json"

line = [ "rails", *ARGV ].join(" ")
File.open(ENV.fetch("FAKE_TOOLS_LOG"), "a") { |file| file.puts(line) }
control = ENV["FAKE_CONTROL"] && File.exist?(ENV["FAKE_CONTROL"]) ? JSON.parse(File.read(ENV["FAKE_CONTROL"])) : {}
command = ARGV.first == "generate" ? ARGV.first(2).join(" ") : ARGV.first

puts "fake rails: db:prepare sees #{ENV[control["echo"]]}" if command == "db:prepare" && control["echo"]
if Array(control["fail"]).include?(command)
  puts "fake rails: #{command} failed"
  exit 1
end
if Array(control["sleep"]).include?(command)
  puts "fake rails: #{command} is hanging"
  sleep
end

def write_new(path, content)
  return if File.exist?(path)

  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
end

case command
when "-T"
  [ "db:prepare", "action_agent:sandbox:manifest", *control["tasks"] ].each { |task| puts "bin/rails #{task}  # #{task}" }
when "generate active_agent:install"
  write_new("config/active_agent.yml", "development:\n  openai:\n    service: OpenAI\n")
  write_new("app/agents/application_agent.rb", "class ApplicationAgent < ActiveAgent::Base\nend\n")
when "generate action_agent:install"
  write_new("config/initializers/action_agent.rb", "ActionAgent.configure { |config| }\n")
  write_new("db/migrate/20260101000000_create_active_agent_dashboard_tables.rb", "# fixture migration\n")
  routes = File.read("config/routes.rb")
  File.write("config/routes.rb", routes.sub("draw do\n", "draw do\n  mount ActionAgent::Engine => \"/activeagents\"\n"))
when "db:prepare"
  write_new("db/schema.rb", "# fixture schema\n")
when "action_agent:sandbox:manifest"
  File.write(ENV.fetch("ACTION_AGENT_SANDBOX_MANIFEST"),
    JSON.generate("mcp_path" => "/activeagents/mcp", "mcp_token" => "fixture-mcp-token-0123456789"))
when "server"
  ENV["FAKE_APP_ROOT_STATUS"] = control["root_status"].to_s if control["root_status"]
  exec(RbConfig.ruby, File.join(__dir__, "fake_app_server.rb"), "serve")
end
