require "test_helper"

class TraceConsoleTest < ActionDispatch::IntegrationTest
  setup do
    ActionAgent::TelemetryTrace.delete_all
    @trace = ActionAgent::TelemetryTrace.create!(
      trace_id: SecureRandom.hex(16), service_name: "console-test", timestamp: Time.current,
      agent_class: "ConsoleAgent", agent_action: "respond", status: "ERROR",
      error_message: "Synthetic failure <script>alert(1)</script>", total_duration_ms: 1200,
      total_input_tokens: 42, total_output_tokens: 7,
      spans: [ { "name" => "ConsoleAgent.respond", "type" => "root", "duration_ms" => 1200 } ]
    )
  end

  test "all console pages render without external resources or scripts" do
    [ "/activeagents/console/traces", "/activeagents/console/traces/#{@trace.id}", "/activeagents/console/traces/metrics" ].each do |path|
      get path
      assert_response :success
      assert_select "script, link[rel=stylesheet], [data-controller]", count: 0
      assert_select "style", minimum: 1
      assert_select "a[href='/activeagents/console/traces']", minimum: 1
      assert_select "a[href='/activeagents/console/traces/metrics']", minimum: 1
      assert_select "a[download], iframe, img[src^='http']", count: 0
    end
  end

  test "trace details expand natively and link to a standalone page" do
    get "/activeagents/console/traces"
    assert_select "details summary", text: /ConsoleAgent/
    assert_select "details a[href='/activeagents/console/traces/#{@trace.id}']", text: "Open trace"
    assert_select "details pre", text: /console-test/
    assert_select "script", count: 0
    assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt;"
  end

  test "automatic refresh is opt in and bounded to known intervals" do
    get "/activeagents/console/traces"
    assert_select "meta[http-equiv=refresh]", count: 0
    get "/activeagents/console/traces", params: { refresh: "30", status: "error" }
    assert_select "meta[http-equiv=refresh][content='30']", count: 1
    assert_select "a", text: "Stop refreshing"
    assert_select "a[href='/activeagents/console/traces?status=error']", text: "Stop refreshing"
    get "/activeagents/console/traces", params: { host: "example.invalid", script_name: "//example.invalid" }
    assert_select "a[href^='/activeagents/console/traces?']", text: "Auto-refresh"
    [ "0", "-1", "1;url=https://example.com", "abc" ].each do |refresh|
      get "/activeagents/console/traces", params: { refresh: refresh }
      assert_select "meta[http-equiv=refresh]", count: 0
    end
    get "/activeagents/console/traces/metrics", params: { refresh: "60" }
    assert_select "meta[http-equiv=refresh][content='60']", count: 1
  end

  test "empty pages still render useful navigation" do
    @trace.destroy!
    get "/activeagents/console/traces"
    assert_includes response.body, "No traces yet"
    get "/activeagents/console/traces/metrics"
    assert_includes response.body, "No agent data available yet"
  end

  test "the list defaults to the newest 50 traces and accepts a smaller limit" do
    create_recent_traces(55)

    get "/activeagents/console/traces"
    assert_response :success
    assert_select "section[aria-label='Recent traces'] > details", count: 50
    assert_select "dl.summary div", text: /Total Traces\s*55/

    get "/activeagents/console/traces", params: { limit: "3" }
    assert_response :success
    assert_select "section[aria-label='Recent traces'] > details", count: 3
    links = css_select("details a").map { |link| link["href"] }
    expected = ActionAgent::TelemetryTrace.recent.limit(3).map { |trace| "/activeagents/console/traces/#{trace.id}" }
    assert_equal expected, links
  end

  test "the list clamps zero negative and oversized limits" do
    create_recent_traces(1001)

    { "0" => 1, "-1" => 1, "1000" => 1000, "999999999999999999999" => 1000 }.each do |limit, count|
      get "/activeagents/console/traces", params: { limit: limit }
      assert_response :success
      assert_select "section[aria-label='Recent traces'] > details", count: count
    end
  end

  test "blank malformed and structured limits fall back to 50 traces" do
    create_recent_traces(55)

    [ "", "abc", "3oops", "1.5", [ "2" ], { value: "2" } ].each do |limit|
      get "/activeagents/console/traces", params: { limit: limit }
      assert_response :success
      assert_select "section[aria-label='Recent traces'] > details", count: 50
    end
  end

  test "the list applies filters before the limit and keeps full summary counts" do
    matching = @trace
    create_recent_traces(5, clear: false)

    get "/activeagents/console/traces", params: {
      limit: "1", agent: "ConsoleAgent", service: "console-test", status: "error",
      start_date: 1.hour.ago.iso8601, end_date: 1.hour.from_now.iso8601
    }
    assert_response :success
    assert_select "section[aria-label='Recent traces'] > details", count: 1
    assert_select "details a[href='/activeagents/console/traces/#{matching.id}']", count: 1
    assert_select "dl.summary div", text: /Total Traces\s*6/
  end

  private

  def create_recent_traces(count, clear: true)
    ActionAgent::TelemetryTrace.delete_all if clear
    now = Time.current
    ActionAgent::TelemetryTrace.insert_all!(count.times.map do |index|
      {
        trace_id: "synthetic-list-#{index}", timestamp: now - index.seconds,
        agent_class: "ListAgent", agent_action: "respond", service_name: "list-test",
        status: "OK", spans: [], total_duration_ms: 10,
        total_input_tokens: 1, total_output_tokens: 1
      }
    end)
  end
end
