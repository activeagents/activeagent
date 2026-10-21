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

  setup do
    ActionAgent::Agent.delete_all
    ActionAgent::ApiKey.delete_all
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

  test "a refused dashboard key fails with the facade's explanation" do
    @key.destroy!
    code, _, err = cli("agents", "list")
    assert_equal ActiveAgent::CLI::EXIT_FAILURE, code
    assert_includes err, "refused the API key"
  end
end
