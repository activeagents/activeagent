# frozen_string_literal: true

module ActiveAgent
  class CLI
    # `activeagent catalogs|agents ...`, through the MCP facade's dashboard
    # tools: scenario catalogs are listed, imported (or the import
    # previewed) and exported as the dashboard's Catalogs page does it, and
    # agents are listed with their versions.
    module ResourceCommands
      CATALOG_FORMATS = %w[yaml json].freeze
      CATALOG_MODES = %w[replace merge].freeze

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

      # Imports a catalog's document (YAML, or the JSON `catalogs export
      # --format json` writes, which YAML reads). Products, sets and
      # scenarios are matched by key, so importing the same file twice
      # changes nothing; --mode merge keeps what the document leaves out.
      # --preview shows what the import would change and writes nothing.
      def catalogs_import(argv)
        arguments = {}
        preview = false
        argv = parse(argv, "catalogs import FILE [--name KEY] [--mode replace|merge] [--preview]") do |p|
          p.on("--name KEY", "The catalog key when the document sets no `catalog:`") { |v| arguments[:name] = v }
          p.on("--mode MODE", CATALOG_MODES, "replace (the default) makes the catalog the document; merge keeps what it leaves out") do |v|
            arguments[:mode] = v
          end
          p.on("--preview", "Show what the import would change, without applying it") { preview = true }
        end
        return EXIT_SUCCESS unless argv

        path = require_argument(argv, "FILE", "catalogs import FILE")
        arguments[:document] = read_text_file(path)
        return catalogs_preview(arguments) if preview

        payload = client.tool("catalogs_import", arguments)
        emit(payload) do
          catalog = payload.fetch("catalog", {})
          @out.puts "Imported catalog #{catalog["key"]} (#{catalog["product_count"]} products, #{catalog["scenario_count"]} scenarios)."
          Array(payload["products"]).each do |product|
            sets = Array(product["sets"]).map { |set| "#{set["key"]} (#{set["scenario_count"]})" }
            @out.puts "  #{product["key"]}#{" -> #{product["agent"]}" if product["agent"]}: #{sets.join(", ")}"
          end
        end
      end

      def catalogs_preview(arguments)
        payload = client.tool("catalogs_preview", arguments)
        emit(payload) do
          catalog = payload.fetch("catalog", {})
          # The catalog's own action is about its record (name, description);
          # what its products, sets and scenarios would do is the change list.
          verdict = { "create" => "created", "update" => "updated" }.fetch(catalog["action"], "kept as it is")
          @out.puts "Preview (#{payload["mode"]}): catalog #{catalog["key"]} would be #{verdict}; " \
                    "#{payload["scenario_count"]} scenarios in the document."
          counts = payload.fetch("counts", {}).reject { |action, _| action == "unchanged" }
          @out.puts "Changes: #{counts.empty? ? "none" : counts.map { |action, count| "#{count} #{action}" }.join(", ")}"
          table(Array(payload["changes"]), {
            "ACTION" => ->(c) { c["action"] },
            "LEVEL" => ->(c) { c["level"] },
            "PATH" => ->(c) { c["path"] }
          }, empty: "Nothing would change.")
        end
      end

      # Writes a catalog's canonical document from the dashboard's records:
      # the whole catalog, or one product or set of it. The same document
      # the Catalogs page's Export YAML downloads; --format json writes it
      # as JSON instead.
      def catalogs_export(argv)
        arguments = {}
        output = nil
        argv = parse(argv, "catalogs export KEY [--product KEY [--set KEY]] [--format yaml|json] [-o FILE]") do |p|
          p.on("--product KEY", "Only this product") { |v| arguments[:product] = v }
          p.on("--set KEY", "Only this set of --product") { |v| arguments[:set] = v }
          p.on("--format FORMAT", CATALOG_FORMATS, "yaml (the default; json when FILE ends in .json) or json") { |v| arguments[:format] = v }
          p.on("-o", "--output FILE", "Write to FILE instead of standard output") { |v| output = v }
        end
        return EXIT_SUCCESS unless argv

        arguments[:catalog] = require_argument(argv, "KEY", "catalogs export KEY")
        arguments[:format] ||= output.to_s.end_with?(".json") ? "json" : "yaml"
        payload = client.tool("catalogs_export", arguments)
        if @options[:json]
          @out.puts JSON.pretty_generate(payload)
          return EXIT_SUCCESS
        end

        write_output(payload["document"].to_s, output) do
          "Wrote catalog #{payload.dig("catalog", "key")} (#{payload["format"]}) to #{output}."
        end
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

      # An agent's versions, newest first, with what each changed.
      def agents_versions(argv)
        arguments = {}
        argv = parse(argv, "agents versions AGENT [--limit N]") do |p|
          p.on("--limit N", "At most N versions (max 50)") { |v| arguments[:limit] = positive_integer(v, "--limit") }
        end
        return EXIT_SUCCESS unless argv

        arguments[:agent] = require_argument(argv, "AGENT (a slug or id)", "agents versions AGENT")
        payload = client.tool("agents_versions", arguments)
        emit(payload) do
          agent = payload.fetch("agent", {})
          @out.puts "#{agent["name"]} (#{agent["slug"]}): #{agent["version_count"]} versions"
          table(payload.fetch("versions", []), {
            "VERSION" => ->(v) { v["version_number"] },
            "CREATED" => ->(v) { v["created_at"] },
            "BY" => ->(v) { v["created_by"] },
            "RELEASE" => ->(v) { v["release"] ? (v["revision"] || v["release_digest"].to_s[0, 12]) : nil },
            "SUMMARY" => ->(v) { v["change_summary"] },
            "CHANGED" => ->(v) { v["diff"].is_a?(Hash) ? v["diff"].keys.join(", ") : nil }
          }, empty: "No versions.")
          @out.puts "(more versions; raise --limit)" if payload["truncated"]
        end
      end
    end

    include ResourceCommands
  end
end
