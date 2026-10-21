# frozen_string_literal: true

module ActiveAgent
  class CLI
    # `activeagent catalogs|agents|traces ...`, through the MCP facade. The
    # commands whose dashboard route only takes a browser session today
    # (catalog export and import preview, agent versions) exit
    # EXIT_UNAVAILABLE naming the route they need.
    module ResourceCommands
      DURATION = /\A(\d+)([smhd]?)\z/
      DURATION_MINUTES = { "" => 1, "m" => 1, "h" => 60, "d" => 24 * 60 }.freeze

      private

      def catalogs_list(argv)
        argv = parse(argv, "catalogs list")
        return EXIT_SUCCESS unless argv

        catalogs = client.tool("catalogs_list").fetch("catalogs", [])
        emit(catalogs: catalogs) do
          table(catalogs, {
            "KEY" => ->(c) { c["key"] },
            "NAME" => ->(c) { c["name"] },
            "PRODUCTS" => ->(c) { c["product_count"] },
            "SCENARIOS" => ->(c) { c["scenario_count"] },
            "SOURCE" => ->(c) { c["source_path"] || c["source_kind"] },
            "UPDATED" => ->(c) { c["updated_at"] }
          }, empty: "No scenario catalogs.")
        end
      end

      # Imports a catalog's YAML document. Products, sets and scenarios are
      # matched by key, so importing the same file twice changes nothing.
      def catalogs_import(argv)
        name = nil
        preview = false
        argv = parse(argv, "catalogs import FILE [--name KEY] [--preview]") do |p|
          p.on("--name KEY", "The catalog key when the document sets no `catalog:`") { |v| name = v }
          p.on("--preview", "Show what the import would change, without applying it") { preview = true }
        end
        return EXIT_SUCCESS unless argv

        path = require_argument(argv, "FILE", "catalogs import FILE")
        unavailable("catalogs import --preview", "POST <mount>/api/scenario_catalogs/preview") if preview
        document = begin
          File.read(path)
        rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
          raise Error.new("Cannot read #{path} (#{e.class})", exit_code: EXIT_USAGE)
        end

        payload = client.tool("catalogs_import", document: document, name: name)
        emit(payload) do
          catalog = payload.fetch("catalog", {})
          @out.puts "Imported catalog #{catalog["key"]} (#{catalog["product_count"]} products, #{catalog["scenario_count"]} scenarios)."
          Array(payload["products"]).each do |product|
            sets = Array(product["sets"]).map { |set| "#{set["key"]} (#{set["scenario_count"]})" }
            @out.puts "  #{product["key"]}#{" -> #{product["agent"]}" if product["agent"]}: #{sets.join(", ")}"
          end
        end
      end

      def catalogs_export(argv)
        argv = parse(argv, "catalogs export KEY [-o FILE]") { |p| p.on("-o", "--output FILE", "Write to FILE") }
        return EXIT_SUCCESS unless argv

        require_argument(argv, "KEY", "catalogs export KEY")
        unavailable("catalogs export", "GET <mount>/api/scenario_catalogs/:id/export")
      end

      # The agents the key reaches, from the facade's agent:// resources.
      def agents_list(argv)
        argv = parse(argv, "agents list")
        return EXIT_SUCCESS unless argv

        resources = Array(client.mcp("resources/list")&.fetch("resources", []))
        agents = resources.map do |resource|
          { "slug" => resource["uri"].to_s.delete_prefix("agent://"), "name" => resource["name"], "description" => resource["description"] }
        end
        emit(agents: agents) do
          table(agents, { "SLUG" => ->(a) { a["slug"] }, "NAME" => ->(a) { a["name"] }, "DESCRIPTION" => ->(a) { a["description"] } },
                empty: "No agents.")
        end
      end

      def agents_versions(argv)
        argv = parse(argv, "agents versions AGENT")
        return EXIT_SUCCESS unless argv

        require_argument(argv, "AGENT", "agents versions AGENT")
        unavailable("agents versions", "GET <mount>/api/agents/:id/versions")
      end

      def traces_list(argv)
        arguments = {}
        argv = parse(argv, "traces list [--agent NAME] [--since 24h] [--status error|ok] [--limit N]") do |p|
          p.on("--agent AGENT", "An agent class name or a dashboard agent's slug") { |v| arguments[:agent] = v }
          p.on("--since DURATION", "How far back: minutes, or 30m, 6h, 7d (default 24h)") { |v| arguments[:since_minutes] = since_minutes(v) }
          p.on("--status STATUS", %w[error ok], "Only failed (error) or successful (ok) traces") { |v| arguments[:status] = v }
          p.on("--service NAME", "Only this reporting service") { |v| arguments[:service] = v }
          p.on("--limit N", "At most N traces (max 100)") { |v| arguments[:limit] = positive_integer(v, "--limit") }
        end
        return EXIT_SUCCESS unless argv
        raise Error.new("unexpected arguments: #{argv.join(" ")}", exit_code: EXIT_USAGE) unless argv.empty?

        payload = client.tool("traces_search", arguments)
        traces = payload.fetch("traces", [])
        emit(payload) do
          table(traces, {
            "TRACE" => ->(t) { t["short_id"] },
            "TIME" => ->(t) { t["timestamp"] },
            "AGENT" => ->(t) { [ t["agent"], t["action"] ].compact.join("#") },
            "MODEL" => ->(t) { t["model"] },
            "STATUS" => ->(t) { t["status"] },
            "MS" => ->(t) { t["duration_ms"] },
            "TOKENS" => ->(t) { t.dig("tokens", "total") }
          }, empty: "No traces in the last #{payload["window_minutes"]} minutes.")
          @out.puts "(more traces match; raise --limit or narrow the filters)" if payload["truncated"]
        end
      end

      # Minutes in a duration such as 90, 30m, 6h or 7d; seconds round up
      # to a whole minute.
      def since_minutes(value)
        match = DURATION.match(value.to_s.strip.downcase)
        raise Error.new("--since must be minutes or a duration such as 30m, 6h or 7d", exit_code: EXIT_USAGE) unless match

        amount = match[1].to_i
        minutes = match[2] == "s" ? (amount / 60.0).ceil : amount * DURATION_MINUTES.fetch(match[2])
        raise Error.new("--since must be at least a minute", exit_code: EXIT_USAGE) unless minutes.positive?

        minutes
      end
    end

    include ResourceCommands
  end
end
