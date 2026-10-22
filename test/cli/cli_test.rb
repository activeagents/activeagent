# frozen_string_literal: true

# The CLI loads without Rails or the framework, as the executable does.
require "minitest/autorun"
require "webmock/minitest"
require "stringio"
require "tmpdir"
require_relative "../../lib/active_agent/cli"

class ActiveAgentCLITest < Minitest::Test
  CLI = ActiveAgent::CLI
  URL = "https://dashboard.example.test/activeagents"
  MCP = "#{URL}/mcp"
  REPORTS = "#{URL}/api/evaluation_reports"
  KEY = "aa_cli_test_key"
  INGEST_KEY = "ingest-cli-test-key"

  class TTYStringIO < StringIO
    def tty? = true
  end

  def setup
    super
    @dir = Dir.mktmpdir("activeagent-cli")
    @credentials = File.join(@dir, "activeagent", "credentials.yml")
    @env = { "ACTIVEAGENT_URL" => URL, "ACTIVEAGENT_API_KEY" => KEY, "ACTIVEAGENT_INGEST_KEY" => INGEST_KEY }
    @sleeps = []
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  # Runs the CLI in process and returns [exit code, stdout, stderr].
  def cli(*argv, env: @env, input: StringIO.new, out: StringIO.new, now: nil)
    err = StringIO.new
    clock = now || -> { @sleeps.sum }
    code = CLI.start(argv, out: out, err: err, input: input, env: env, credentials_path: @credentials,
                           sleeper: ->(seconds) { @sleeps << seconds }, clock: clock)
    [ code, out.string, err.string ]
  end

  def rpc_body(result)
    { status: 200, body: { jsonrpc: "2.0", id: 1, result: result }.to_json, headers: { "Content-Type" => "application/json" } }
  end

  def stub_rpc(method, result)
    stub_request(:post, MCP).with(headers: { "Authorization" => "Bearer #{KEY}" }) { |request| JSON.parse(request.body)["method"] == method }
      .to_return(rpc_body(result))
  end

  # Stubs one dashboard tool; +responses+ answer successive calls in turn.
  def stub_tool(name, *responses, arguments: nil, error: nil)
    stub = stub_request(:post, MCP).with(headers: { "Authorization" => "Bearer #{KEY}" }) do |request|
      body = JSON.parse(request.body)
      body["method"] == "tools/call" && body.dig("params", "name") == name &&
        (arguments.nil? || arguments.all? { |key, value| body.dig("params", "arguments", key.to_s) == value })
    end
    return stub.to_return(rpc_body(content: [], structuredContent: { error: error }, isError: true)) if error

    responses.each_with_index { |payload, i| (i.zero? ? stub : stub.then).to_return(rpc_body(content: [], structuredContent: payload)) }
    stub
  end

  def run_payload(status, passed: 0, evaluated: 0, results: [])
    { evaluation: { id: 7, name: "Orders" },
      run: { id: 41, run_id: "dashboard-run-41-20261022100000", status: status, samples_evaluated: evaluated, samples_passed: passed },
      results: results }
  end

  def envelope(run_id: "run-1")
    { "version" => 1, "run_id" => run_id, "source" => "support-app", "agent_name" => "SupportBot", "suite" => "orders",
      "report" => { "results" => [ { "scenario_key" => "status_1", "answer" => "Shipped" } ], "metadata" => { "run_id" => run_id } } }
  end

  # -- core ---------------------------------------------------------------

  def test_version_help_and_usage_errors
    assert_equal [ 0, "activeagent #{ActiveAgent::VERSION}\n", "" ], cli("--version")
    code, out, = cli("help")
    assert_equal 0, code
    assert_includes out, "evals"
    assert_includes out, "Exit codes"

    code, _, err = cli("deploy")
    assert_equal CLI::EXIT_USAGE, code
    assert_includes err, "unknown command 'deploy'"
    assert_equal CLI::EXIT_USAGE, cli("evals", "frobnicate").first
    assert_equal CLI::EXIT_USAGE, cli("evals", "list", "--bogus").first
  end

  def test_no_url_is_a_configuration_error
    code, _, err = cli("agents", "list", env: {})
    assert_equal CLI::EXIT_CONFIG, code
    assert_includes err, "activeagent login"
  end

  def test_an_http_url_is_refused_except_on_loopback
    code, _, err = cli("agents", "list", env: @env.merge("ACTIVEAGENT_URL" => "http://dashboard.example.test/activeagents"))
    assert_equal CLI::EXIT_USAGE, code
    assert_includes err, "HTTPS"
  end

  def test_login_verifies_the_key_and_stores_a_private_profile
    stub_rpc("initialize", serverInfo: { name: "activeagents", version: "1.0" })

    code, out, = cli("login", "--url", "#{URL}/", "--key", KEY, "--profile", "staging", env: {})

    assert_equal 0, code, out
    assert_includes out, "profile 'staging'"
    assert_equal 0o600, File.stat(@credentials).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(@credentials)).mode & 0o777
    assert_equal({ "staging" => { "url" => URL, "api_key" => KEY } }, YAML.safe_load_file(@credentials))

    # A later command finds the profile by name, without the environment.
    stub_rpc("resources/list", resources: [])
    assert_equal 0, cli("agents", "list", "--profile", "staging", env: {}).first
    assert_equal CLI::EXIT_CONFIG, cli("agents", "list", "--profile", "missing", env: {}).first
  end

  def test_login_reads_the_key_from_standard_input
    stub_rpc("initialize", serverInfo: {})
    code, = cli("login", "--url", URL, env: {}, input: StringIO.new("#{KEY}\n"))
    assert_equal 0, code
    assert_equal KEY, YAML.safe_load_file(@credentials).dig("default", "api_key")
  end

  def test_a_refused_key_is_not_stored
    stub_request(:post, MCP).to_return(status: 401, body: { error: "Unauthorized: #{KEY} is unknown" }.to_json)

    code, _, err = cli("login", "--url", URL, "--key", KEY, env: {})

    assert_equal CLI::EXIT_FAILURE, code
    assert_includes err, "refused the API key"
    refute_includes err, KEY
    refute File.exist?(@credentials)
  end

  def test_the_environment_overrides_the_stored_profile
    stub_rpc("initialize", serverInfo: {})
    cli("login", "--url", "https://old.example.test/activeagents", "--key", "aa_old", "--no-verify", env: {})
    stub_rpc("resources/list", resources: [ { uri: "agent://support", name: "Support" } ])

    code, out, = cli("agents", "list")

    assert_equal 0, code
    assert_includes out, "support"
  end

  def test_logout_removes_the_profile
    cli("login", "--url", URL, "--key", KEY, "--no-verify", env: {})
    assert_equal [ 0, "Removed profile 'default'.\n", "" ], cli("logout", env: {})
    refute File.exist?(@credentials)
  end

  def test_status_checks_both_keys
    stub_rpc("initialize", serverInfo: { name: "activeagents" })
    stub_request(:post, REPORTS).with(headers: { "Authorization" => "Bearer #{INGEST_KEY}" }, body: "{}")
      .to_return(status: 422, body: { error: "version must be 1" }.to_json)

    code, out, = cli("status", "--json")

    assert_equal 0, code
    status = JSON.parse(out)
    assert status["ok"]
    assert status.dig("checks", "dashboard", "ok")
    assert_equal REPORTS, status.dig("checks", "collector", "endpoint")
  end

  def test_status_fails_when_the_collector_refuses_the_ingest_key
    stub_rpc("initialize", serverInfo: {})
    stub_request(:post, REPORTS).to_return(status: 401, body: { error: "Invalid API key" }.to_json)

    code, out, = cli("status")

    assert_equal CLI::EXIT_FAILURE, code
    assert_match(/API key:\s+accepted/, out)
    assert_match(/Collector: FAILED: .*HTTP 401/, out)
  end

  def test_a_tool_the_dashboard_does_not_offer_is_unavailable
    stub_request(:post, MCP).to_return(rpc_body(nil).merge(body: { jsonrpc: "2.0", id: 1, error: { code: -32602, message: "Unknown tool: evaluations_list" } }.to_json))

    code, _, err = cli("evals", "list")

    assert_equal CLI::EXIT_UNAVAILABLE, code
    assert_includes err, "mcp_dashboard_tools"
  end

  def test_a_tool_refusal_is_reported_without_the_key
    stub_tool("evaluations_list", error: "No agent #{KEY}")
    code, _, err = cli("evals", "list", "--agent", "nobody")
    assert_equal CLI::EXIT_FAILURE, code
    assert_includes err, "No agent [FILTERED]"
  end

  # -- evals --------------------------------------------------------------

  def test_evals_list_prints_a_table_or_json
    evaluations = [ { id: 7, name: "Orders", agent: { slug: "support" }, scenario_count: 3, run_count: 2,
                      latest_run: { status: "complete", samples_evaluated: 3, samples_passed: 2 } } ]
    stub_tool("evaluations_list", { evaluations: evaluations }, arguments: { "agent" => "support", "limit" => 5 })

    code, out, = cli("evals", "list", "--agent", "support", "--limit", "5")
    assert_equal 0, code
    assert_match(/^ID\s+NAME\s+AGENT/, out)
    assert_match(/^7\s+Orders\s+support\s+3\s+2\s+complete\s+2\/3$/, out)

    code, out, = cli("--json", "evals", "list", "--agent", "support", "--limit", "5")
    assert_equal 0, code
    assert_equal "Orders", JSON.parse(out).dig("evaluations", 0, "name")
  end

  def test_evals_runs_resolves_an_evaluation_by_name
    stub_tool("evaluations_list", { evaluations: [ { id: 7, name: "Orders" }, { id: 8, name: "Refunds" } ] })
    stub_tool("evaluations_get", { evaluation: { id: 7, name: "Orders" },
                                   runs: [ { id: 41, number: 2, status: "complete", samples_evaluated: 4, samples_passed: 4,
                                             run_id: "dashboard-run-41-20261022100000" } ] },
              arguments: { "evaluation_id" => 7 })

    code, out, = cli("evals", "runs", "Orders")

    assert_equal 0, code, out
    assert_match(/^RUN\s+#\s+STATUS\s+PASSED\s+SCORE\s+CREATED\s+RUN_ID$/, out)
    assert_match(/^41\s+2\s+complete\s+4\/4\s+-\s+-\s+dashboard-run-41-20261022100000$/, out)
  end

  def test_evals_run_without_wait_returns_once_started
    stub_tool("evaluations_run", run_payload("pending"), arguments: { "evaluation_id" => 7, "models" => [ "a", "b" ] })

    code, out, err = cli("evals", "run", "7", "--models", "a,b")

    assert_equal 0, code
    assert_includes err, "Started run 41"
    assert_includes out, "Status: pending"
  end

  def test_evals_run_waits_and_passes_the_gate
    stub_tool("evaluations_run", run_payload("pending"))
    stub_tool("evaluation_runs_get", run_payload("running", evaluated: 1), run_payload("complete", passed: 9, evaluated: 10),
              arguments: { "run_id" => 41, "failed_only" => true })

    code, out, = cli("evals", "run", "7", "--min-pass-rate", "80%", "--interval", "2")

    assert_equal 0, code, out
    assert_equal [ 2 ], @sleeps
    assert_includes out, "(90.0%), threshold 80.0%"
    assert_includes out, "Report: activeagent evals report dashboard-run-41-20261022100000"
    assert_match(/PASS$/, out)
  end

  def test_evals_run_fails_the_gate_below_the_threshold
    failures = [ { scenario_key: "refund_1", model: "mock/beta", status: "failed", fault: "missing_capability", trace_id: "abc" } ]
    stub_tool("evaluations_run", run_payload("pending"))
    stub_tool("evaluation_runs_get", run_payload("complete", passed: 7, evaluated: 10, results: failures))

    code, out, = cli("evals", "run", "7", "--min-pass-rate", "0.8", "--json")

    assert_equal CLI::EXIT_GATE, code
    result = JSON.parse(out)
    assert_equal "fail", result["verdict"]
    assert_in_delta 0.7, result["pass_rate"]
    assert_equal "refund_1", result.dig("results", 0, "scenario_key")
  end

  def test_evals_run_fails_the_gate_when_the_run_failed
    stub_tool("evaluations_run", run_payload("pending"))
    stub_tool("evaluation_runs_get", run_payload("failed"))
    code, out, = cli("evals", "run", "7", "--wait")
    assert_equal CLI::EXIT_GATE, code
    assert_match(/FAIL$/, out)
  end

  def test_evals_run_gives_up_after_the_timeout
    stub_tool("evaluations_run", run_payload("pending"))
    stub_tool("evaluation_runs_get", run_payload("running"))

    code, _, err = cli("evals", "run", "7", "--wait", "--timeout", "10", "--interval", "4")

    assert_equal CLI::EXIT_FAILURE, code
    assert_includes err, "still running after 10s"
    assert_equal [ 4, 4, 4 ], @sleeps
  end

  def test_an_invalid_pass_rate_is_a_usage_error
    assert_equal CLI::EXIT_USAGE, cli("evals", "run", "7", "--min-pass-rate", "1.5").first
  end

  def test_evals_report_writes_the_json_envelope
    stub_request(:get, "#{REPORTS}/run-1").with(headers: { "Authorization" => "Bearer #{INGEST_KEY}", "Accept" => "application/json" })
      .to_return(status: 200, body: envelope.to_json)
    path = File.join(@dir, "report.json")

    code, _, err = cli("evals", "report", "run-1", "-o", path)

    assert_equal 0, code, err
    assert_equal envelope, JSON.parse(File.read(path))
  end

  def test_evals_report_asks_for_html_and_markdown
    stub_request(:get, "#{REPORTS}/run%201?format=html").with(headers: { "Accept" => "text/html" })
      .to_return(status: 200, body: "<html>report</html>")
    stub_request(:get, "#{REPORTS}/run%201?format=md").with(headers: { "Accept" => "text/markdown" })
      .to_return(status: 200, body: "## Orders\n")

    assert_equal [ 0, "<html>report</html>\n", "" ], cli("evals", "report", "run 1", "--format", "html")
    assert_equal [ 0, "## Orders\n", "" ], cli("evals", "report", "run 1", "--format", "md")
  end

  def test_evals_report_defaults_to_markdown_on_a_terminal_and_json_otherwise
    stub_request(:get, "#{REPORTS}/run-1?format=md").to_return(status: 200, body: "## Orders\n")
    stub_request(:get, "#{REPORTS}/run-1").to_return(status: 200, body: envelope.to_json)

    assert_equal "## Orders\n", cli("evals", "report", "run-1", out: TTYStringIO.new)[1]
    assert_equal envelope, JSON.parse(cli("evals", "report", "run-1")[1])
  end

  def test_evals_report_tells_a_missing_run_from_a_dashboard_without_the_export
    # The collector's own 404 names the run.
    stub_request(:get, "#{REPORTS}/run-1").to_return(status: 404, body: { error: "No evaluation report with that run_id" }.to_json)
    code, _, err = cli("evals", "report", "run-1")
    assert_equal CLI::EXIT_FAILURE, code
    assert_includes err, "No report for run run-1; `activeagent evals runs EVALUATION` shows each run's RUN_ID (No evaluation report with that run_id)"

    # An older engine has no such route: Rails answers for it.
    [ "", { status: 404, error: "Not Found" }.to_json ].each do |body|
      stub_request(:get, "#{REPORTS}/run-1").to_return(status: 404, body: body)
      code, _, err = cli("evals", "report", "run-1")
      assert_equal CLI::EXIT_UNAVAILABLE, code, body
      assert_includes err, "GET <mount>/api/evaluation_reports/:run_id"
    end

    stub_request(:get, "#{REPORTS}/run-1").to_return(status: 422, body: { error: "Only a complete run can be exported" }.to_json)
    code, _, err = cli("evals", "report", "run-1")
    assert_equal CLI::EXIT_FAILURE, code
    assert_includes err, "HTTP 422 (Only a complete run can be exported)"
  end

  def test_evals_report_refuses_a_body_that_is_not_an_envelope
    stub_request(:get, "#{REPORTS}/run-1").to_return(status: 200, body: { results: [] }.to_json)
    assert_equal CLI::EXIT_FAILURE, cli("evals", "report", "run-1").first
  end

  def test_evals_import_posts_an_envelope_with_the_ingest_key
    path = File.join(@dir, "report.json")
    File.write(path, envelope.to_json)
    request = stub_request(:post, REPORTS).with(headers: { "Authorization" => "Bearer #{INGEST_KEY}" }, body: envelope)
      .to_return(status: 201, body: { run_id: "run-1", status: "complete", id: 5, evaluation_id: 3 }.to_json)

    code, out, = cli("evals", "import", path)

    assert_equal 0, code, out
    assert_includes out, "Imported run run-1 (evaluation 3, run 5)"
    assert_requested request
  end

  def test_evals_import_takes_a_bare_report_with_identities
    path = File.join(@dir, "report.json")
    File.write(path, envelope["report"].to_json)
    stub_request(:post, REPORTS).with { |request| JSON.parse(request.body).slice("run_id", "suite") == { "run_id" => "run-1", "suite" => "orders" } }
      .to_return(status: 200, body: { run_id: "run-1", status: "complete", id: 5, evaluation_id: 3, duplicate: true }.to_json)

    code, out, = cli("evals", "import", path, "--source", "app", "--agent", "Bot", "--suite", "orders")
    assert_equal 0, code, out
    assert_includes out, "Already stored"

    code, _, err = cli("evals", "import", path, "--source", "app")
    assert_equal CLI::EXIT_USAGE, code
    assert_includes err, "agent_name must be a nonempty string"
  end

  def test_evals_import_reports_a_rejection
    path = File.join(@dir, "report.json")
    File.write(path, envelope.to_json)
    stub_request(:post, REPORTS).to_return(status: 409, body: { error: "run-1 holds a different report" }.to_json)

    code, _, err = cli("evals", "import", path)

    assert_equal CLI::EXIT_FAILURE, code
    assert_includes err, "HTTP 409"
  end

  def test_evals_import_of_a_missing_file_is_a_usage_error
    assert_equal CLI::EXIT_USAGE, cli("evals", "import", File.join(@dir, "nope.json")).first
  end

  # -- catalogs, agents, traces --------------------------------------------

  def test_catalogs_list_and_import
    stub_tool("catalogs_list", { catalogs: [ { key: "shop", name: "Shop", product_count: 1, scenario_count: 4, source_kind: "api" } ] })
    path = File.join(@dir, "shop.yml")
    File.write(path, "catalog: shop\nproducts: []\n")
    stub_tool("catalogs_import", { catalog: { key: "shop", product_count: 1, scenario_count: 4 },
                                   products: [ { key: "support", agent: "Support", sets: [ { key: "orders", scenario_count: 4 } ] } ] },
              arguments: { "document" => "catalog: shop\nproducts: []\n" })

    code, out, = cli("catalogs", "list")
    assert_equal 0, code
    assert_match(/^shop\s+Shop\s+1\s+4\s+api/, out)

    code, out, = cli("catalogs", "import", path)
    assert_equal 0, code, out
    assert_includes out, "Imported catalog shop"
    assert_includes out, "support -> Support: orders (4)"
  end

  def test_catalogs_import_preview_shows_the_changes_without_importing
    path = File.join(@dir, "shop.yml")
    File.write(path, "catalog: shop\nproducts: []\n")
    stub_tool("catalogs_preview", { mode: "merge", catalog: { key: "shop", action: "update" }, scenario_count: 4,
                                    counts: { "create" => 1, "unchanged" => 3 },
                                    changes: [ { level: "scenario", path: "support/orders/refund_2", action: "create" } ] },
              arguments: { "document" => "catalog: shop\nproducts: []\n", "mode" => "merge" })

    code, out, = cli("catalogs", "import", path, "--preview", "--mode", "merge")

    assert_equal 0, code, out
    assert_includes out, "Preview (merge): catalog shop would be updated; 4 scenarios in the document."
    assert_includes out, "Changes: 1 create"
    assert_match(%r{^create\s+scenario\s+support/orders/refund_2$}, out)
    assert_not_requested(:post, MCP) { |request| JSON.parse(request.body).dig("params", "name") == "catalogs_import" }
    assert_equal CLI::EXIT_USAGE, cli("catalogs", "import", path, "--mode", "sideways").first
  end

  def test_catalogs_export_writes_the_document_as_yaml_or_json
    stub_tool("catalogs_export", { catalog: { key: "shop" }, format: "yaml", document: "catalog: shop\nproducts: []\n" },
              arguments: { "catalog" => "shop", "format" => "yaml" })
    stub_tool("catalogs_export", { catalog: { key: "shop" }, format: "json", product: "support", document: "{\n  \"catalog\": \"shop\"\n}" },
              arguments: { "catalog" => "shop", "format" => "json", "product" => "support" })

    assert_equal [ 0, "catalog: shop\nproducts: []\n", "" ], cli("catalogs", "export", "shop")

    # A .json file asks for JSON, and --json prints the tool's whole answer.
    path = File.join(@dir, "shop.json")
    code, out, err = cli("catalogs", "export", "shop", "--product", "support", "-o", path)
    assert_equal 0, code, err
    assert_equal "", out
    assert_equal({ "catalog" => "shop" }, JSON.parse(File.read(path)))
    assert_includes err, "Wrote catalog shop (json) to #{path}."
    assert_equal "support", JSON.parse(cli("catalogs", "export", "shop", "--product", "support", "--format", "json", "--json")[1])["product"]
  end

  def test_agents_versions_lists_each_version_with_what_it_changed
    stub_tool("agents_versions", { agent: { id: 3, slug: "support", name: "Support", version_count: 2 },
                                   versions: [ { version_number: 2, created_at: "2026-10-22T10:00:00Z", created_by: "ops", release: true,
                                                 revision: "abc1234", change_summary: "Deploy", diff: { "model" => { "from" => "a", "to" => "b" } } },
                                               { version_number: 1, created_at: "2026-10-21T10:00:00Z", release: false, change_summary: "Initial version" } ],
                                   truncated: true },
              arguments: { "agent" => "support", "limit" => 2 })

    code, out, = cli("agents", "versions", "support", "--limit", "2")

    assert_equal 0, code, out
    assert_includes out, "Support (support): 2 versions"
    assert_match(/^2\s+2026-10-22T10:00:00Z\s+ops\s+abc1234\s+Deploy\s+model$/, out)
    assert_match(/^1\s+2026-10-21T10:00:00Z\s+-\s+-\s+Initial version\s+-$/, out)
    assert_includes out, "raise --limit"
  end

  def test_traces_get_prints_the_trace_and_its_spans
    stub_tool("traces_get", { trace_id: "abcd1234ef", agent: "SupportAgent", action: "reply", model: "gpt-5-mini", status: "ERROR",
                              duration_ms: 120.5, tokens: { total: 30 }, error: "boom",
                              spans: [ { span_id: "root", type: "root", name: "SupportAgent.reply", start: 0, duration: 120.5, status: "ERROR" } ],
                              spans_total: 101, spans_omitted: 100 },
              arguments: { "trace_id" => "abcd1234" })

    code, out, = cli("traces", "get", "abcd1234")

    assert_equal 0, code, out
    assert_includes out, "Trace abcd1234ef: SupportAgent#reply on gpt-5-mini (ERROR, 120.5 ms, 30 tokens)"
    assert_includes out, "Error: boom"
    assert_match(/^root\s+root\s+SupportAgent\.reply\s+0\s+120\.5\s+ERROR$/, out)
    assert_includes out, "(100 more spans; `activeagent traces export abcd1234ef` has them all)"
  end

  def test_traces_export_writes_the_ingest_payload
    payload = { traces: [ { trace_id: "abcd1234ef", service_name: "app", timestamp: "2026-10-22T10:00:00.000000Z", spans: [] } ],
                sdk: { name: "activeagent", version: "1.9.3" } }
    stub_tool("traces_export", payload, arguments: { "trace_id" => "abcd1234ef" })
    path = File.join(@dir, "trace.json")

    code, out, err = cli("traces", "export", "abcd1234ef", "-o", path)

    assert_equal 0, code, err
    assert_equal "", out
    assert_equal JSON.parse(payload.to_json), JSON.parse(File.read(path))
    assert_includes err, "Wrote trace abcd1234ef to #{path}."
    assert_equal JSON.parse(payload.to_json), JSON.parse(cli("traces", "export", "abcd1234ef")[1])
  end

  def test_traces_import_posts_the_payload_with_the_ingest_key
    payload = { "traces" => [ { "trace_id" => "abcd1234ef", "service_name" => "app", "spans" => [] } ],
                "sdk" => { "name" => "activeagent", "version" => "1.9.3" } }
    path = File.join(@dir, "trace.json")
    File.write(path, payload.to_json)
    request = stub_request(:post, "#{URL}/api/traces").with(headers: { "Authorization" => "Bearer #{INGEST_KEY}" }, body: payload)
      .to_return(status: 202, body: "")

    code, out, = cli("traces", "import", path)

    assert_equal 0, code, out
    assert_includes out, "Sent 1 trace to #{URL}/api/traces: abcd1234ef."
    assert_requested request

    # One bare trace is wrapped, and sent as this CLI's own SDK.
    File.write(path, payload["traces"].first.to_json)
    bare = stub_request(:post, "#{URL}/api/traces").with do |r|
      body = JSON.parse(r.body)
      body["traces"] == payload["traces"] && body.dig("sdk", "name") == "activeagent-cli"
    end.to_return(status: 202)
    code, out, = cli("traces", "import", path, "--json")
    assert_equal 0, code, out
    assert_equal [ "abcd1234ef" ], JSON.parse(out)["trace_ids"]
    assert_requested bare

    File.write(path, { "nope" => true }.to_json)
    code, _, err = cli("traces", "import", path)
    assert_equal CLI::EXIT_USAGE, code
    assert_includes err, "holds no traces"
  end

  def test_traces_import_reports_a_refusal_without_the_key
    path = File.join(@dir, "trace.json")
    File.write(path, { "traces" => [ { "trace_id" => "x" } ] }.to_json)
    stub_request(:post, "#{URL}/api/traces").to_return(status: 401, body: { error: "Invalid API key #{INGEST_KEY}" }.to_json)

    code, _, err = cli("traces", "import", path)

    assert_equal CLI::EXIT_FAILURE, code
    assert_includes err, "refused the ingest key"
    assert_includes err, "[FILTERED]"
    refute_includes err, INGEST_KEY

    stub_request(:post, "#{URL}/api/traces").to_return(status: 429, body: { error: "Trace ingest limit reached" }.to_json)
    code, _, err = cli("traces", "import", path)
    assert_equal CLI::EXIT_FAILURE, code
    assert_includes err, "HTTP 429 (Trace ingest limit reached)"
  end

  def test_agents_list_reads_the_agent_resources
    stub_rpc("resources/list", resources: [ { uri: "agent://support", name: "Support", description: "Answers orders" } ])
    code, out, = cli("agents", "list", "--json")
    assert_equal 0, code
    assert_equal [ { "slug" => "support", "name" => "Support", "description" => "Answers orders" } ], JSON.parse(out)["agents"]
  end

  def test_traces_list_converts_since_to_minutes
    stub_tool("traces_search", { traces: [ { short_id: "abcd1234", agent: "SupportAgent", action: "reply", status: "error",
                                             tokens: { total: 120 } } ], truncated: true, window_minutes: 360 },
              arguments: { "since_minutes" => 360, "status" => "error" })

    code, out, = cli("traces", "list", "--since", "6h", "--status", "error")

    assert_equal 0, code, out
    assert_match(/^abcd1234\s+-\s+SupportAgent#reply/, out)
    assert_includes out, "more traces match"
    assert_equal CLI::EXIT_USAGE, cli("traces", "list", "--since", "soon").first
  end
end
