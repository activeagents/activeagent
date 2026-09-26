# frozen_string_literal: true

module ActionAgent
  # The runtime manifest: how a booted checkout tells the sandbox backend
  # where its MCP facade answers and which bearer token opens it.
  #
  #   { "mcp_path": "/activeagents/mcp", "mcp_token": "aa_..." }
  #
  # The checked-out app writes it with `bin/rails action_agent:sandbox:manifest`
  # (it mounts this engine, so the task ships with it), and a backend reads it
  # back with .parse. Both halves live here so they cannot drift.
  module SandboxManifest
    # Where the manifest task writes, when set; stdout otherwise.
    PATH_ENV = "ACTION_AGENT_SANDBOX_MANIFEST"
    # The dashboard API key the manifest hands out, created once per checkout.
    KEY_NAME = "Checkout sandbox runtime"

    class Error < StandardError; end

    module_function

    # Builds the manifest inside the booted app: the engine's MCP path under
    # wherever the app mounts it, and an API key for the MCP facade.
    #
    # @param routes [ActionDispatch::Routing::RouteSet] the app's routes
    # @return [Hash{String => String}]
    def generate(routes: Rails.application.routes)
      # Rails 8 loads routes lazily in development and test; the mount is
      # invisible until they are.
      Rails.application.reload_routes_unless_loaded if Rails.application.respond_to?(:reload_routes_unless_loaded)

      mount = ActiveAgent::Telemetry::Configuration.new.mount_path_in(routes)
      raise Error, "ActionAgent::Engine is not mounted in this app's routes" if mount.nil?

      { "mcp_path" => "#{mount}/mcp", "mcp_token" => api_key.token }
    end

    # The checkout's own dashboard API key for the facade. Reused across
    # runs so a re-run manifest does not mint a key per boot. A host that
    # owns keys by account or user gets a key with no owner, which reaches
    # no agents over MCP — the manifest says so rather than failing.
    def api_key
      ActionAgent::ApiKey.find_or_create_by!(name: KEY_NAME)
    end

    # Reads a manifest a checkout wrote.
    #
    # @param json [String]
    # @return [Hash{String => String}] with "mcp_path" and "mcp_token"
    def parse(json)
      data = JSON.parse(json.to_s)
      raise Error, "the manifest is not a JSON object" unless data.is_a?(Hash)

      path = data["mcp_path"]
      unless path.is_a?(String) && path.start_with?("/")
        raise Error, "the manifest names no mcp_path (expected a path such as /activeagents/mcp)"
      end

      token = data["mcp_token"]
      raise Error, "the manifest's mcp_token is not a string" unless token.nil? || token.is_a?(String)

      { "mcp_path" => path, "mcp_token" => token }
    rescue JSON::ParserError => e
      raise Error, "the manifest is not JSON (#{e.message.truncate(120)})"
    end
  end
end
