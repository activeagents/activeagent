# frozen_string_literal: true

# A stand-in for `bin/rails action_agent:sandbox:manifest`, run by
# LocalSandboxBackendTest as sandbox.yml's `manifest`: writes the runtime
# manifest to $ACTION_AGENT_SANDBOX_MANIFEST, or with `garbage`, something
# that is not a manifest at all.
#
#   ruby fake_manifest.rb [garbage]
require "json"

path = ENV.fetch("ACTION_AGENT_SANDBOX_MANIFEST")

if ARGV[0] == "garbage"
  File.write(path, "this is not JSON")
else
  File.write(path, JSON.generate("mcp_path" => "/activeagents/mcp", "mcp_token" => "fixture-mcp-token-0123456789"))
end

puts "fake manifest: wrote #{path}"
