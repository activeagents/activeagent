#!/usr/bin/env ruby
# frozen_string_literal: true

# A stand-in for the Claude Code CLI, run by LocalSandboxBackendTest through
# ActionAgent.claude_code_command. It speaks just enough of
# `claude -p --output-format stream-json`:
#
# * --help lists --permission-prompts, unless the first argument is
#   --legacy-cli (an older CLI without it).
# * `auth status --json` reports a login when $HOME/.claude/.credentials.json
#   exists (where `claude /login` leaves one), along with an email the
#   dashboard must never pass on; logged out, it says so and exits 1. After
#   --broken-auth as the first argument it prints garbage and exits 2.
# * The prompt is read from stdin, and the invocation (argv, environment,
#   working directory, prompt) is written to invocation.json in
#   $CLAUDE_CONFIG_DIR, or in $HOME/.claude without one (a session on the
#   machine's own login).
# * A prompt containing SLEEP starts a `sleep` in its process group, writes
#   both pids to $CLAUDE_CONFIG_DIR/pids.json and waits to be stopped. With
#   STUBBORN too it ignores SIGTERM, so only SIGKILL stops it.
# * A prompt containing COMMIT commits everything in the checkout, as a
#   session may on its own, and reports a result.
# * Anything else edits README.md, deletes OBSOLETE.md, writes a new NOTES.md,
#   echoes the Claude Code credential on stdout, stderr and into NOTES.md (all
#   of which must be scrubbed), prints a line that is not JSON, and reports a
#   result.
require "json"

$stdout.sync = true
$stderr.sync = true

legacy = ARGV.first == "--legacy-cli"
broken_auth = ARGV.first == "--broken-auth"
argv = legacy || broken_auth ? ARGV.drop(1) : ARGV

config_dir = ENV["CLAUDE_CONFIG_DIR"] || File.join(ENV.fetch("HOME"), ".claude")

if argv.first(2) == %w[auth status]
  if broken_auth
    puts "Segmentation fault (not really)"
    exit 2
  end

  if File.exist?(File.join(config_dir, ".credentials.json"))
    puts JSON.pretty_generate(
      "loggedIn" => true, "authMethod" => "claude.ai", "apiProvider" => "firstParty",
      "email" => "developer@example.com", "orgName" => "Fixture Org", "subscriptionType" => "max"
    )
    exit 0
  end

  puts JSON.pretty_generate("loggedIn" => false, "authMethod" => "none", "apiProvider" => "firstParty")
  exit 1
end

if argv.include?("--help")
  puts "Usage: claude [options] [command] [prompt]"
  puts "  -p, --print                      Print response and exit"
  puts "  --permission-prompts <target>    Who answers permission prompts with --print" unless legacy
  exit 0
end

prompt = $stdin.read
File.write(File.join(config_dir, "invocation.json"),
  JSON.generate("argv" => argv, "env" => ENV.to_h, "cwd" => Dir.pwd, "prompt" => prompt))

def emit(event)
  puts JSON.generate(event)
end

emit("type" => "system", "subtype" => "init", "model" => "fake-claude", "session_id" => "fake-session", "cwd" => Dir.pwd)

if prompt.include?("SLEEP")
  trap("TERM") { warn "fake claude: ignoring SIGTERM" } if prompt.include?("STUBBORN")
  child = Process.spawn("sleep", "600")
  File.write(File.join(config_dir, "pids.json"), JSON.generate("pid" => Process.pid, "child_pid" => child))
  emit("type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "Sleeping until stopped" } ] })
  # A trapped SIGTERM wakes a sleep, so it sleeps again.
  loop { sleep 600 }
end

if prompt.include?("COMMIT")
  system("git", "add", "--all", exception: true)
  system("git", "-c", "user.name=Fake Claude", "-c", "user.email=claude@example.com", "-c", "commit.gpgsign=false",
    "commit", "-q", "-m", "Committed by the fake Claude Code", exception: true)
  emit("type" => "result", "subtype" => "success", "is_error" => false, "result" => "Committed", "num_turns" => 1)
  exit 0
end

credential = ENV["ANTHROPIC_API_KEY"].to_s
File.open("README.md", "a") { |file| file.puts("Edited by the fake Claude Code.") }
File.delete("OBSOLETE.md")
File.write("NOTES.md", "A new file the session wrote (credential: #{credential}).\n")

warn "fake claude: authenticating with #{credential}"
emit("type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => "My credential is #{credential}" } ] })
puts "not json at all"
emit("type" => "assistant", "message" => { "content" => [
  { "type" => "tool_use", "id" => "toolu_1", "name" => "Edit", "input" => { "file_path" => "README.md" } }
] })
emit(
  "type" => "result", "subtype" => "success", "is_error" => false, "result" => "Edited README.md",
  "num_turns" => 2, "duration_ms" => 12, "total_cost_usd" => 0.001, "session_id" => "fake-session",
  "usage" => { "input_tokens" => 10, "output_tokens" => 5 }
)
exit 0
