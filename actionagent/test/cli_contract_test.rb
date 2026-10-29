# frozen_string_literal: true

require "test_helper"
require "active_agent/cli"
require "stringio"
require "tmpdir"

# The `activeagent` CLI against the engine itself, with WebMock handing each
# request to the dummy app rather than the network: the commands read and
# write what the MCP facade and the report collector actually serve, so a
# change to either that breaks the CLI fails here.
class CliContractTest < ActiveSupport::TestCase
  URL = "http://localhost/activeagents"
  INGEST_KEY = "install-key-for-cli"

  CATALOG = <<~YAML
    catalog: shop
    products:
      - key: support
        agent: support
        sets:
          - key: orders
            scenarios:
              - key: status_1
                prompt: Where is order 1?
          - key: refunds
            scenarios:
              - key: refund_1
                prompt: Refund order 1.
  YAML

  setup do
    ActionAgent::Agent.delete_all
    ActionAgent::ApiKey.delete_all
    ActionAgent::ScenarioCatalog.delete_all
    ActionAgent::TelemetryTrace.delete_all
    ActionAgent.ingest_api_key = INGEST_KEY
    @key = ActionAgent::ApiKey.create!(name: "CLI")
    @agent = ActionAgent::Agent.create!(name: "Support", slug: "support", provider: "mock", model: "mock-model",
                                        instructions: "Answer from data.", status: :active)
    @dir = Dir.mktmpdir("activeagent-cli-contract")
    stub_request(:any, %r{\A#{Regexp.escape(URL)}/}).to_rack(Rails.application)
  end

  teardown do
    ActionAgent.ingest_api_key = nil
    FileUtils.rm_rf(@dir)
  end

  def cli(*argv)
    out = StringIO.new
    err = StringIO.new
    env = { "ACTIVEAGENT_URL" => URL, "ACTIVEAGENT_API_KEY" => @key.token, "ACTIVEAGENT_INGEST_KEY" => INGEST_KEY }
    code = ActiveAgent::CLI.start(argv, out: out, err: err, env: env, credentials_path: File.join(@dir, "credentials.yml"))
    [ code, out.string, err.string ]
  end

  def json(*argv)
    code, out, err = cli(*argv, "--json")
    assert_equal 0, code, err
    JSON.parse(out)
  end

  # A one-scenario, one-model report as ActiveAgent::Evals::Report writes it.
  def report(run_id)
    evals = ActiveAgent::Evals
    spec = evals::ModelSpec.new(label: "mock-model", provider: "mock", model: "mock-model")
    scenario = evals::Scenario.from_hash({ "key" => "status_1", "group" => "status", "prompt" => "Where is order 1?" })
    result = evals::Result.new(
      scenario: scenario, spec: spec, scores: { "response_present" => 1.0 }, score: 1.0, status: "passed",
      replay: evals::Replay.new(answer: "Shipped", tool_calls: [], duration_ms: 10, input_tokens: 5, output_tokens: 2,
                                metadata: { "run_id" => run_id })
    )
    evals::Report.new(results: [ result ], models: [ spec ], metadata: { "run_id" => run_id, "suite" => "orders" })
  end

  test "status accepts the dashboard key on the facade and the ingest key on the collector" do
    status = json("status")
    assert status["ok"], status.inspect

    ActionAgent.ingest_api_key = "another-key"
    code, out, = cli("status")
    assert_equal ActiveAgent::CLI::EXIT_FAILURE, code
    assert_match(/Collector: FAILED: .*HTTP 401/, out)
  end

  test "evals import stores a report that evals list and evals runs then read" do
    path = File.join(@dir, "report.json")
    File.write(path, JSON.generate(
      "version" => 1, "run_id" => "cli-run-1", "source" => "support-app", "agent_name" => "Support", "suite" => "orders",
      "report" => report("cli-run-1").to_h
    ))

    code, out, err = cli("evals", "import", path)
    assert_equal 0, code, err
    assert_match(/Imported run cli-run-1/, out)

    evaluations = json("evals", "list")["evaluations"]
    assert_equal 1, evaluations.size, evaluations.inspect
    evaluation = evaluations.first

    runs = json("evals", "runs", evaluation["name"])["runs"]
    assert_equal 1, runs.size
    assert_equal "complete", runs.first["status"]
  end

  test "catalogs import and list round-trip a YAML catalog" do
    path = File.join(@dir, "shop.yml")
    File.write(path, <<~YAML)
      catalog: shop
      products:
        - key: support
          agent: support
          sets:
            - key: orders
              scenarios:
                - key: status_1
                  prompt: Where is order 1?
    YAML

    code, out, err = cli("catalogs", "import", path)
    assert_equal 0, code, err
    assert_includes out, "Imported catalog shop"

    catalogs = json("catalogs", "list")["catalogs"]
    assert_equal [ "shop" ], catalogs.map { |catalog| catalog["key"] }
    assert_equal 1, catalogs.first["scenario_count"]
  end

  test "evals run starts a scenario suite's run through the facade" do
    evaluation = @agent.evaluations.new(name: "Support lookups", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "order_lookup", prompt: "Where is order 1?", group: "orders")
    evaluation.save!

    started = json("evals", "run", "Support lookups")

    assert_equal evaluation.id, started.dig("evaluation", "id")
    assert_equal evaluation.evaluation_runs.sole.id, started.dig("run", "id")
    assert started["background"]
  end

  test "agents list and traces list read the key's agents and telemetry" do
    assert_equal [ "support" ], json("agents", "list")["agents"].map { |agent| agent["slug"] }
    assert_equal 60, json("traces", "list", "--since", "1h")["window_minutes"]
  end

  test "evals report reads a run back as the envelope evals import sends, and as Markdown and HTML" do
    path = File.join(@dir, "report.json")
    File.write(path, JSON.generate(
      "version" => 1, "run_id" => "cli-run-2", "source" => "support-app", "agent_name" => "Support", "suite" => "orders",
      "report" => report("cli-run-2").to_h
    ))
    assert_equal 0, cli("evals", "import", path).first

    # evals runs names the run_id the report is read back under.
    evaluation = json("evals", "list")["evaluations"].sole
    assert_equal "cli-run-2", json("evals", "runs", evaluation["id"].to_s)["runs"].sole["run_id"]

    exported = File.join(@dir, "exported.json")
    code, _, err = cli("evals", "report", "cli-run-2", "-o", exported)
    assert_equal 0, code, err
    envelope = JSON.parse(File.read(exported))
    assert_equal [ 1, "cli-run-2", "support-app", "Support", "orders" ], envelope.values_at("version", "run_id", "source", "agent_name", "suite")
    assert_equal "Shipped", envelope.dig("report", "results", 0, "answer")

    # Posting the export back is an identical retry, so the file moves a run
    # between installs.
    code, out, = cli("evals", "import", exported)
    assert_equal 0, code, out
    assert_match(/Already stored run cli-run-2/, out)

    code, out, = cli("evals", "report", "cli-run-2", "--format", "md")
    assert_equal 0, code, out
    assert_match(/\A# /, out)
    assert_includes out, "status_1"

    code, out, = cli("evals", "report", "cli-run-2", "--format", "html")
    assert_equal 0, code, out
    assert_includes out, "<html lang=\"en\""

    code, _, err = cli("evals", "report", "no-such-run")
    assert_equal ActiveAgent::CLI::EXIT_FAILURE, code
    assert_includes err, "No report for run no-such-run"
  end

  test "catalogs export writes the records back, and import --preview shows what a changed document would do" do
    path = File.join(@dir, "shop.yml")
    File.write(path, CATALOG)
    assert_equal 0, cli("catalogs", "import", path).first

    code, out, = cli("catalogs", "export", "shop")
    assert_equal 0, code, out
    document = YAML.safe_load(out)
    assert_equal "shop", document["catalog"]
    assert_equal %w[orders refunds], document.dig("products", 0, "sets").map { |set| set["key"] }

    json_path = File.join(@dir, "shop.json")
    assert_equal 0, cli("catalogs", "export", "shop", "--product", "support", "--set", "refunds", "-o", json_path).first
    narrowed = JSON.parse(File.read(json_path))
    assert_equal [ "refunds" ], narrowed.dig("products", 0, "sets").map { |set| set["key"] }

    # The preview of a document with one more scenario writes nothing.
    File.write(path, CATALOG + "          - key: refund_2\n            prompt: Refund order 2.\n")
    code, out, = cli("catalogs", "import", path, "--preview")
    assert_equal 0, code, out
    assert_includes out, "Preview (replace): catalog shop would be kept as it is; 3 scenarios in the document."
    assert_match(%r{^create\s+scenario\s+support/refunds/refund_2$}, out)
    assert_equal 2, json("catalogs", "list")["catalogs"].sole["scenario_count"]

    # The narrowed JSON export reads back as a merge, changing nothing.
    code, out, = cli("catalogs", "import", json_path, "--mode", "merge")
    assert_equal 0, code, out
    assert_equal 2, json("catalogs", "list")["catalogs"].sole["scenario_count"]
  end

  test "agents versions lists the agent's versions with what each changed" do
    @agent.update!(instructions: "Answer from data, briefly.")

    versions = json("agents", "versions", "support")["versions"]
    assert_equal [ 2, 1 ], versions.map { |version| version["version_number"] }
    assert_equal({ "from" => "Answer from data.", "to" => "Answer from data, briefly." }, versions.first.dig("diff", "instructions"))

    code, out, = cli("agents", "versions", "support")
    assert_equal 0, code, out
    assert_includes out, "Support (support): 2 versions"
    assert_match(/^2\s+.*\binstructions$/, out)
  end

  test "traces export and import move a trace between dashboards" do
    ActionAgent::TelemetryTrace.create_from_payload({
      "trace_id" => "cli-trace-1", "service_name" => "support-app", "environment" => "test",
      "timestamp" => Time.current.iso8601(6), "resource_attributes" => { "host.name" => "web-1" },
      "spans" => [ {
        "span_id" => "root", "parent_span_id" => nil, "name" => "SupportAgent.answer", "type" => "root",
        "duration_ms" => 120.0, "status" => "OK", "tokens" => { "input" => 10, "output" => 5 },
        "attributes" => { "agent.class" => "SupportAgent", "agent.action" => "answer" }
      } ]
    }, { "name" => "activeagent", "version" => "1.9.3" })
    path = File.join(@dir, "trace.json")

    assert_equal 0, cli("traces", "export", "cli-trace-1", "-o", path).first
    payload = JSON.parse(File.read(path))
    assert_equal "cli-trace-1", payload.dig("traces", 0, "trace_id")
    assert_equal({ "host.name" => "web-1" }, payload.dig("traces", 0, "resource_attributes"))
    assert_equal "1.9.3", payload.dig("sdk", "version")

    ActionAgent::TelemetryTrace.delete_all
    code, out, = cli("traces", "import", path)
    assert_equal 0, code, out
    assert_includes out, "Sent 1 trace to #{URL}/api/traces: cli-trace-1."
    stored = ActionAgent::TelemetryTrace.find_by!(trace_id: "cli-trace-1")
    assert_equal "SupportAgent", stored.agent_class
    assert_equal 15, stored.total_tokens
    assert_equal({ "host.name" => "web-1" }, stored.resource_attributes)
    assert_equal "1.9.3", stored.sdk_info["version"]

    # Importing the same file again stores nothing more.
    assert_equal 0, cli("traces", "import", path).first
    assert_equal 1, ActionAgent::TelemetryTrace.where(trace_id: "cli-trace-1").count

    assert_equal "cli-trace-1", json("traces", "get", "cli-trac")["trace_id"]
    assert_equal [ "cli-trace-1" ], json("traces", "list")["traces"].map { |trace| trace["trace_id"] }
  end

  test "a refused dashboard key fails with the facade's explanation" do
    @key.destroy!
    code, _, err = cli("agents", "list")
    assert_equal ActiveAgent::CLI::EXIT_FAILURE, code
    assert_includes err, "refused the API key"
  end
end
