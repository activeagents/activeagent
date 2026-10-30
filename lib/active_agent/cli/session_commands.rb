# frozen_string_literal: true

module ActiveAgent
  class CLI
    # login, logout and status: the profile a command runs as, and whether
    # the dashboard accepts it.
    module SessionCommands
      MCP_PROTOCOL_VERSION = "2025-03-26"

      private

      # Checks the key against the dashboard before storing it, unless
      # --no-verify. The key comes from --key, ACTIVEAGENT_API_KEY, or a
      # prompt (echo off on a terminal), so it need not sit in shell history.
      def login(argv)
        values = {}
        verify = true
        argv = parse(argv, "login --url URL [--key KEY] [--ingest-key KEY] [--profile NAME]") do |p|
          p.on("--key KEY", "A dashboard API key (Settings -> API Keys); prompted for when omitted") { |v| values["api_key"] = v }
          p.on("--ingest-key KEY", "The mount's ingest key, for evals import/report, when it differs from --key") { |v| values["ingest_key"] = v }
          p.on("--[no-]verify", "Check the key against the dashboard first (default: on)") { |v| verify = v }
        end
        return EXIT_SUCCESS unless argv
        raise Error.new("unexpected arguments: #{argv.join(" ")}", exit_code: EXIT_USAGE) unless argv.empty?

        stored = @credentials[profile_name]
        url = @options[:url] || env_value("ACTIVEAGENT_URL") || stored["url"]
        raise Error.new("missing --url, the dashboard's mount (e.g. https://ops.example.com/activeagents)", exit_code: EXIT_USAGE) if url.to_s.empty?

        values["url"] = Client.parse_url(url).to_s
        values["api_key"] ||= env_value("ACTIVEAGENT_API_KEY") || prompt_for_key
        values["ingest_key"] ||= env_value("ACTIVEAGENT_INGEST_KEY") || stored["ingest_key"]
        raise Error.new("an API key is required", exit_code: EXIT_USAGE) if values["api_key"].to_s.strip.empty?
        values["api_key"] = values["api_key"].strip

        server = verify ? mcp_initialize(Client.new(url: values["url"], api_key: values["api_key"])) : nil
        @credentials.save(profile_name, values)

        emit(profile: profile_name, url: values["url"], verified: verify, server: server, credentials: @credentials.path) do
          @out.puts "Logged in to #{values["url"]} as profile '#{profile_name}'#{" (not verified)" unless verify}."
          @out.puts "Saved to #{@credentials.path}"
        end
      end

      def logout(argv)
        argv = parse(argv, "logout [--profile NAME]")
        return EXIT_SUCCESS unless argv

        removed = @credentials.delete(profile_name)
        emit(profile: profile_name, removed: removed) do
          @out.puts(removed ? "Removed profile '#{profile_name}'." : "No profile '#{profile_name}' was stored.")
        end
      end

      # Two checks, one per key: the MCP facade's initialize with the API key,
      # and Publisher#verify! against the report collector with the ingest
      # key. Exits EXIT_FAILURE when either fails.
      def status(argv)
        argv = parse(argv, "status [--profile NAME]")
        return EXIT_SUCCESS unless argv

        client
        checks = {
          "dashboard" => check { { "server" => mcp_initialize(client) } },
          "collector" => check { client.publisher.verify! && { "endpoint" => client.reports_endpoint } }
        }
        ok = checks.values.all? { |result| result["ok"] }

        emit(profile: profile_name, url: client.url, ok: ok, checks: checks) do
          @out.puts "Profile:   #{profile_name}"
          @out.puts "Dashboard: #{client.url}"
          @out.puts "API key:   #{checks["dashboard"]["ok"] ? "accepted (#{client.mcp_endpoint})" : "FAILED: #{checks["dashboard"]["error"]}"}"
          @out.puts "Collector: #{checks["collector"]["ok"] ? "accepted (#{client.reports_endpoint})" : "FAILED: #{checks["collector"]["error"]}"}"
        end
        ok ? EXIT_SUCCESS : EXIT_FAILURE
      end

      def check
        { "ok" => true }.merge(yield || {})
      rescue Error, ActiveAgent::Evals::Publisher::Error => e
        { "ok" => false, "error" => e.message }
      end

      # The facade's serverInfo, which an accepted key gets back.
      def mcp_initialize(client)
        result = client.mcp("initialize", protocolVersion: MCP_PROTOCOL_VERSION, capabilities: {},
                                          clientInfo: { name: "activeagent-cli", version: self.class.version })
        result.is_a?(Hash) ? result["serverInfo"] : nil
      end

      def prompt_for_key
        if @input.respond_to?(:tty?) && @input.tty?
          require "io/console"
          @err.print "Dashboard API key: "
          key = @input.noecho(&:gets)
          @err.puts
          key
        else
          @input.gets
        end
      end
    end

    include SessionCommands
  end
end
