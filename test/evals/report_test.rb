# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsReportTest < ActiveSupport::TestCase
  include EvalsTestSupport

  Result = ActiveAgent::Evals::Result
  Diagnosis = ActiveAgent::Evals::Diagnosis
  Report = ActiveAgent::Evals::Report

  AVAILABLE = %w[find_tickets inbox_status index_status].freeze
  LINKS = { "mcp" => "/activeagents/mcp/%{key}", "tools" => "/activeagents/tools", "instructions" => "/activeagents/agents/1/edit" }.freeze
  SERVERS = {
    "index_status" => { "key" => "help_desk_status", "name" => "Help Desk Status", "status" => "enabled" },
    "lookup_order" => { "key" => "order_desk", "name" => "Order Desk", "status" => "available" },
    "refund_order" => { "key" => "order_desk", "name" => "Order Desk", "status" => "available" }
  }.freeze

  def models
    @models ||= [ spec("gpt-5-mini"), spec("openrouter/meta-llama/llama-3.1-8b") ]
  end

  def gpt
    models.first
  end

  def llama
    models.last
  end

  def resolver
    ->(name) { SERVERS[name] }
  end

  # A result whose diagnosis comes from the real Diagnosis, so the evidence
  # has the shape the report reads; `judge:` adds the judge's refinement.
  def result(scenario, spec, replay, score: 1.0, judge: nil)
    scores = { "response_present" => replay.answer.present? ? 1.0 : 0.0 }
    diagnosis = Diagnosis.call(scenario: scenario, replay: replay, scores: scores, score: score, available_tools: AVAILABLE)&.to_h
    if diagnosis && judge
      diagnosis["judge"] = judge
      diagnosis["recommendation"] = judge["recommendation"] if judge["recommendation"]
    end
    Result.new(scenario: scenario, spec: spec, replay: replay, scores: scores, score: score,
               status: replay.errored? ? "errored" : (diagnosis ? "failed" : "passed"), diagnosis: diagnosis)
  end

  # Five scenarios in three groups under two models: every fault type once,
  # a passing pair, and one "available but not called" exception.
  def results
    inbox = scenario("s_inbox", "Is the support inbox receiving email?", group: "desk", tools: [ "inbox_status" ])
    queue = scenario("s_queue", "Is the reply queue backed up?", group: "desk", tools: [ "inbox_status" ])
    index = scenario("s_index", "Is the help center search index up to date?", group: "desk", tools: [ "index_status" ])
    order = scenario("s_order", "Where is order <b>ABC-123</b>?", group: "orders", tools: [ "lookup_order" ])
    history = scenario("s_history", "Who changed the shipping policy?", group: "history")
    long_error = "no Article with id=0 — the article was deleted before the tool ran, try again with a valid id"

    [
      result(inbox, gpt, replay(answer: "All healthy.", tool_calls: [ { "name" => "inbox_status" } ], duration_ms: 2_500, input_tokens: 80, output_tokens: 9, cost: 0.0012)),
      result(inbox, llama, replay(answer: "Healthy.", tool_calls: [ { "name" => "inbox_status" }, { "name" => "check_async" } ], duration_ms: 900)),
      result(queue, gpt, replay(answer: "The queue is clear.", tool_calls: [ { "name" => "find_tickets" } ]), score: 0.5),
      result(queue, llama, replay(answer: "Nothing is waiting.", tool_calls: [ { "name" => "inbox_status" } ])),
      result(index, gpt, replay(answer: "The index looks fine.", tool_calls: [ { "name" => "inbox_status" } ]), score: 0.5),
      result(index, llama, replay(answer: "The index is stale.", tool_calls: [ { "name" => "index_status", "error" => true, "detail" => long_error }, { "name" => "index_status", "error" => true, "detail" => long_error } ]), score: 0.5),
      result(order, gpt, replay(answer: "<img src=x onerror=alert(1)> no such order", tool_calls: [ { "name" => "find_tickets" } ]), score: 0.5),
      result(order, llama, replay(answer: "I don't have access to order data."), score: 0.5,
             judge: { "recommendation" => "Give the agent an order lookup tool.",
                      "suggested_tool" => { "name" => "refund_order", "description" => "Refunds an order" },
                      "instruction_change" => "Use lookup_order for order questions." }),
      result(history, gpt, replay(answer: "Someone did."), score: 0.4,
             judge: { "recommendation" => "Add an audit tool.", "suggested_tool" => { "name" => "record_history", "description" => "Who changed what" } }),
      result(history, llama, replay(answer: "Alice changed it on Monday."))
    ]
  end

  def report(**options)
    Report.new(results: results, models: models, metadata: { "evaluation" => "Support suite", "run" => 3 }, **options)
  end

  # --- fix items -------------------------------------------------------------

  def test_fix_items_group_faults_in_recommendation_order_and_name_the_tools_per_fault_type
    items = report.fix_items
    by_fault = items.to_h { |item| [ item["fault"], item ] }

    assert_equal "expected_tool_not_called", items.first["fault"]
    assert_equal %w[expected_tool_not_called instruction\ change low_quality missing_capability tool_error], items.map { |item| item["fault"] }.sort
    assert_equal items.map { |item| item["fault"] }.first(4), report.recommendations.map { |entry| entry["fault"] }

    missing = by_fault["expected_tool_not_called"]
    assert_equal "fault", missing["kind"]
    assert_equal 3, missing["count"]
    assert_equal %w[s_queue s_index s_order], missing["scenario_keys"]
    assert_equal [ "gpt-5-mini" ], missing["models"]
    assert_equal "missing tools", missing["tools_label"]
    assert_equal %w[lookup_order], missing["tools"].map { |tool| tool["name"] }
    assert_match(/\As_queue is the exception: Expected inbox_status to be called; the agent called find_tickets\./, missing["note"])
    assert_match(/expects lookup_order, which the agent does not have/, missing["recommendation"],
                 "the card speaks for the scenarios whose tool was missing, not for the exception it notes")
    assert_no_match(/answered with find_tickets/, missing["recommendation"])
    assert_nil missing["quote"]

    failing = by_fault["tool_error"]
    assert_equal "failing tools", failing["tools_label"]
    assert_equal 1, failing["tools"].size, "failing tools are deduplicated by name"
    assert_equal "index_status", failing["tools"].first["name"]
    assert_equal 60, failing["tools"].first["note"].length
    assert_equal({ "label" => "Open failing tools", "hint" => "Tools ->", "path" => nil }, failing["action"])

    capability = by_fault["missing_capability"]
    assert_equal "suggested tools", capability["tools_label"]
    assert_equal %w[refund_order lookup_order], capability["tools"].map { |tool| tool["name"] }
    assert_equal "Give the agent an order lookup tool.", capability["recommendation"]
    assert_equal "Open suggested tools", capability["action"]["label"]

    quality = by_fault["low_quality"]
    assert_equal %w[record_history], quality["tools"].map { |tool| tool["name"] }
    assert_nil quality["server"]
    assert_nil quality["note"]

    instruction = by_fault["instruction change"]
    assert_equal "instruction", instruction["kind"]
    assert_equal "Use lookup_order for order questions.", instruction["quote"]
    assert_equal [ "s_order" ], instruction["scenario_keys"]
    assert_equal [ llama.label ], instruction["models"]
    assert_equal [], instruction["tools"]
    assert_nil instruction["recommendation"], "the judge's recommendation is already the fault card's text"
    assert_equal({ "label" => "Add to instructions", "hint" => "Agent -> Instructions", "path" => nil }, instruction["action"])
  end

  def test_fix_items_without_tools_carry_no_label_or_action
    report = Report.new(models: models.first(1), results: [
      result(scenario("s_1", "Explain the policy"), gpt, replay(answer: "Short."), score: 0.2)
    ])
    item = report.fix_items.first

    assert_equal "low_quality", item["fault"]
    assert_nil item["tools_label"]
    assert_equal [], item["tools"]
    assert_nil item["action"]
  end

  def test_a_tool_resolver_attaches_servers_and_links_fill_the_action_paths
    items = report(tool_resolver: resolver, agent_name: "Assistant", links: LINKS).fix_items
    by_fault = items.to_h { |item| [ item["fault"], item ] }

    missing = by_fault["expected_tool_not_called"]
    assert_equal({ "key" => "order_desk", "name" => "Order Desk", "status" => "available" }, missing["server"])
    assert_equal "Order Desk", missing["tools"].first["note"], "a missing tool's note is its server"
    assert_equal({ "label" => "Enable Order Desk for Assistant", "hint" => "MCP Services ->", "path" => "/activeagents/mcp/order_desk" }, missing["action"])

    failing = by_fault["tool_error"]
    assert_equal "help_desk_status", failing["tools"].first.dig("server", "key")
    assert_equal "/activeagents/tools", failing["action"]["path"]
    assert_nil failing["server"], "only missing tools resolve to a shared server"

    assert_nil by_fault["low_quality"]["tools"].first["server"]
    assert_equal "/activeagents/agents/1/edit", by_fault["instruction change"]["action"]["path"]
  end

  def test_missing_tools_on_an_enabled_server_or_across_servers_fall_back_to_the_tools_page
    enabled = ->(_name) { { "key" => "order_desk", "name" => "Order Desk", "status" => "enabled" } }
    item = report(tool_resolver: enabled, links: LINKS).fix_items.first

    assert_equal "enabled", item.dig("server", "status")
    assert_equal({ "label" => "Open tools", "hint" => "Tools ->", "path" => "/activeagents/tools" }, item["action"])

    split = ->(name) { { "key" => name, "status" => nil } }
    item = Report.new(results: results, models: models, tool_resolver: split).fix_items.first

    assert_equal "unknown", item["tools"].first.dig("server", "status")
    assert_equal "lookup_order", item["tools"].first.dig("server", "name"), "a server without a name reads as its key"
  end

  def test_agent_name_defaults_and_the_resolver_is_asked_once_per_tool
    calls = []
    report = report(tool_resolver: ->(name) { calls << name; nil })
    report.fix_items

    assert_equal "the agent", report.agent_name
    assert_equal calls.uniq, calls
  end

  def test_to_h_and_to_json_are_unchanged_by_fix_items
    parsed = JSON.parse(report(tool_resolver: resolver, links: LINKS).to_json)

    assert_equal %w[models criteria recommendations verdict metadata results], parsed.keys
    assert_not parsed.key?("fix_items")
    assert_equal 10, parsed["results"].size
  end

  # --- HTML --------------------------------------------------------------------

  def test_to_html_is_a_self_contained_page_on_the_design_tokens
    html = report.to_html

    assert_includes html, "<!doctype html>"
    assert_match(/<html lang="en">/, html)
    assert_includes html, "<title>Evaluation — 5 scenarios × 2 models</title>"
    assert_not_includes html, "http://", "the page must not reference external assets"
    assert_not_includes html, "<script"
    assert_includes html, "--color-accent-ui: #ef4444;"
    assert_includes html, "@media (prefers-color-scheme: dark)"
    assert_includes html, ":root:not(.theme-light) {"
    assert_includes html, ":root.theme-dark {"

    styles = html[%r{<style>(.*?)</style>}m, 1].gsub(/:root[^{]*\{[^}]*\}/, "")
    assert_no_match(/#[0-9a-f]{3,8}\b/i, styles, "colors come only from the token variables")
    assert_includes styles, "var(--color-success)"
    assert_includes styles, "var(--font-mono)"
  end

  def test_theme_pins_the_palette_on_the_html_element
    assert_match(/<html lang="en" class="theme-dark">/, report.to_html(theme: "dark"))
    assert_match(/<html lang="en" class="theme-light">/, report.to_html(theme: :light))
    assert_match(/<html lang="en">/, report.to_html(theme: "sepia"))
  end

  def test_html_renders_stat_tiles_models_panel_and_the_judges_pick
    html = report.to_html

    assert_includes html, "Scenario runs"
    assert_includes html, "4 / 10 passed"
    assert_includes html, %(<div class="value tone-error">40%</div>)
    assert_includes html, "5 fix items"
    assert_includes html, "judged by rules", "a pass-rate ranking is not a judge — the dashboard reads it the same way"
    assert_includes html, "judge's pick"
    assert_not_includes html, "Winner"
    assert_includes html, %(<span class="name">llama-3.1-8b</span><span class="provider">openrouter/meta-llama</span>)
    assert_includes html, %(<span class="ratio tone-error">1/5</span>)
    assert_includes html, %(<span class="ratio tone-error">3/5</span>)
    assert_includes html, "expected tool not called ×3"
    assert_includes html, "<b>2.5s</b>"
    assert_includes html, "<b>900ms</b>"
    assert_includes html, "<b>$0.0012</b>"
    assert_includes html, %(<span class="tok"><span class="in">in</span> 80 · <span class="out">out</span> 9</span>),
                    "token counts stay plain in the secondary line, as they are on the dashboard"
    assert_includes html, %(<span class="micro sm">Verdict</span>)
  end

  def test_html_renders_fix_cards_with_tools_server_note_and_actions
    html = report(tool_resolver: resolver, agent_name: "Assistant", links: LINKS).to_html

    assert_includes html, "What to fix"
    assert_includes html, "5 items · 6 faults across 4 scenarios"
    assert_includes html, %(<span class="glyph tone-error">[!]</span>)
    assert_includes html, %(<span class="glyph tone-info">[i]</span>)
    assert_includes html, %(<span class="badge error">expected tool not called ×3</span>)
    assert_includes html, %(<span class="badge info">instruction change</span>)
    assert_includes html, "3 scenarios · gpt-5-mini"
    assert_includes html, "s_order · judge suggestion"
    assert_includes html, "missing tools"
    assert_includes html, %(<b>lookup_order</b><span class="note">Order Desk</span>)
    assert_includes html, %(<span>served by</span><b>Order Desk</b><span class="badge warning xs">available · not enabled for Assistant</span>)
    assert_includes html, "s_queue is the exception"
    assert_includes html, %(<a class="btn" target="_top" href="/activeagents/mcp/order_desk">Enable Order Desk for Assistant</a><span class="hint">MCP Services -&gt;</span>),
                    "the action leaves the dashboard's report iframe rather than nesting the dashboard in it"
    assert_includes html, "“Use lookup_order for order questions.”"
    assert_not_includes html, "expected_tool_not_called"
  end

  def test_html_without_links_renders_the_route_hint_only
    html = report(tool_resolver: resolver).to_html

    assert_not_includes html, %(class="btn")
    assert_includes html, %(<div class="action"><span class="hint">MCP Services -&gt;</span></div>)
  end

  def test_html_matrix_colors_calls_against_expectations_and_links_to_the_details
    html = report.to_html

    assert_includes html, %(<span class="group-name">desk</span><span class="count">3 scenarios</span>)
    assert_includes html, %(<span class="group-pass">1/3 passed</span><span class="group-pass">2/3 passed</span>)
    assert_includes html, %(<span class="group-pass text-error">0/1 passed</span><span class="group-pass text-success">1/1 passed</span>)
    assert_includes html, %(<span class="expect">index_status</span>)
    assert_includes html, %(<span class="g tone-success">[+]</span><span class="s tone-success">1.00</span>)
    assert_includes html, %(<span class="g tone-error">[!]</span><span class="s tone-error">0.50</span><span class="f">tool error</span>)
    assert_includes html, %(<span class="call-hit">inbox_status</span><span>check_async</span>)
    assert_includes html, %(<span class="call-err">index_status ✗ ×2</span>)
    assert_includes html, "no tools called"
    assert_includes html, %(<a href="#scenario-s_history">s_history</a>)
    assert_includes html, %(<div id="scenario-s_history">)
    assert_includes html, "<details>"
    assert_includes html, %(<span class="badge success">passed · 1.00</span>)
    assert_includes html, %(<span class="badge error">failed · 0.50</span>)
    assert_includes html, "2.5s · 89 tokens · $0.0012"
    assert_includes html, "<b>[!] tool error</b> — Tool index_status returned an error while answering."
    assert_includes html, "expects <b>lookup_order</b>"
    assert_includes html, "<footer>"
    assert_includes html, "judge rules"
    assert_includes html, "criteria response present"
    assert_includes html, "evaluation Support suite"
  end

  def test_html_escapes_prompts_answers_tool_names_and_metadata
    report = Report.new(
      results: [ Result.new(
        scenario: scenario("xss_1", "<script>alert(1)</script> in a prompt", tools: [ "<b>tool</b>" ]),
        spec: gpt,
        replay: replay(answer: "<img src=x onerror=alert(1)>", tool_calls: [ { "name" => "<i>call</i>" } ]),
        scores: { "response_present" => 1.0 }, score: 1.0, status: "passed"
      ) ],
      models: [ gpt ], metadata: { "evaluation" => "<em>suite</em>" }
    )
    html = report.to_html

    assert_not_includes html, "<script>alert(1)</script>"
    assert_not_includes html, "<img src=x"
    assert_not_includes html, "<b>tool</b>"
    assert_not_includes html, "<i>call</i>"
    assert_not_includes html, "<em>suite</em>"
    assert_includes html, "&lt;script&gt;"
    assert_includes html, "&lt;em&gt;suite&lt;/em&gt;"
    assert_includes html, "[+] no faults"
  end

  def test_a_single_model_report_has_no_pick_or_verdict_and_an_errored_run_reads_as_such
    report = Report.new(models: models.first(1), results: [
      result(scenario("s_1", "Ping"), gpt, ActiveAgent::Evals::Replay.failed(RuntimeError.new("provider down")), score: nil)
    ])
    html = report.to_html

    assert_not_includes html, "judge's pick"
    assert_not_includes html, "Verdict"
    assert_includes html, "<title>Evaluation — 1 scenario × 1 model</title>"
    assert_includes html, %(<span class="badge error">errored</span>)
    assert_includes html, "Error: RuntimeError: provider down"
    assert_includes html, "answer not retained for this run"
    assert_includes html, %(<span class="scope">1 scenario</span>), "one model column is no comparison to scope a fix to"
    assert_not_includes html, "1 scenario · gpt-5-mini"
  end

  def test_the_matrix_renders_the_whole_prompt
    prompt = "Refund order ABC-123, #{([ 'check it was not already refunded' ] * 8).join(', ')}."
    html = Report.new(models: models.first(1), results: [
      result(scenario("s_long", prompt), gpt, replay(answer: "Refunded."))
    ]).to_html

    assert_operator prompt.length, :>, 200
    assert_includes html, %(<div class="prompt">#{prompt}</div>), "the matrix cell wraps; it does not truncate"
    assert_not_includes html, "…"
  end

  def test_a_clean_run_keeps_the_what_to_fix_section
    html = Report.new(models: models.first(1), results: [
      result(scenario("s_1", "Who changed the shipping policy?"), gpt, replay(answer: "Alice did, on Monday."))
    ]).to_html

    assert_includes html, "What to fix"
    assert_includes html, "0 items · 0 faults across 0 scenarios"
    assert_includes html, %(<div class="nothing">[+] nothing to fix</div>)
  end

  def test_an_empty_report_still_renders
    html = Report.new(results: [], models: models).to_html

    assert_includes html, "<title>Evaluation — 0 scenarios × 2 models</title>"
    assert_includes html, "0 / 0 passed"
    assert_not_includes html, "What to fix", "a report over no results has nothing to fix and nothing to say about it"
  end

  # --- a rebuilt run's verdict ------------------------------------------------

  def test_a_rebuilt_report_keeps_its_judge_identity_in_json_and_markdown
    rebuilt = Report.new(results: [], models: [], judge_label: "recorded-support-judge")

    assert_equal "recorded-support-judge", JSON.parse(rebuilt.to_json)["judge"]
    assert_includes rebuilt.to_markdown, "Judged by `recorded-support-judge`."
    assert_not_includes rebuilt.to_markdown, "No judge"
  end

  def test_a_recorded_verdict_is_rendered_as_recorded_rather_than_ranked_again
    recorded = { "winner" => gpt.label, "rationale" => "Slower, but it never claimed a tool it did not have.", "judge" => "gpt-4o-mini" }
    rebuilt = report(verdict: recorded, judge_label: "gpt-4o-mini")
    html = rebuilt.to_html

    assert_equal recorded, rebuilt.verdict
    assert_equal gpt.label, rebuilt.winner, "the pass-rate ranking would have picked the other model"
    assert_includes html, %(<span class="name">gpt-5-mini</span><span class="provider">openai</span><span class="badge info xs">judge's pick</span>)
    assert_not_includes html, %(<span class="provider">openrouter/meta-llama</span><span class="badge info xs">judge's pick</span>)
    assert_includes html, "Slower, but it never claimed a tool it did not have."
    assert_includes html, "pick · gpt-5-mini", "the MODELS tile names the recorded pick too"
    assert_includes html, "judged by gpt-4o-mini"
    assert_includes html, %(<span class="chip"><b>judge</b>gpt-4o-mini</span>)
    assert_includes html, %(<span class="nowrap">judge gpt-4o-mini</span>)
  end

  def test_a_recorded_verdict_does_not_ask_the_judge_again
    asked = 0
    judge = fake_judge(label: "gpt-4o-mini") do
      asked += 1
      %({"winner": "gpt-5-mini", "rationale": "Asked again."})
    end
    rebuilt = report(judge: judge, verdict: { "winner" => llama.label, "rationale" => "Recorded.", "judge" => "gpt-4o-mini" })

    assert_equal "Recorded.", rebuilt.verdict["rationale"]
    assert_includes rebuilt.to_html, "judged by gpt-4o-mini"
    assert_equal 0, asked, "a run that was already ruled on is not re-litigated"
  end
end
