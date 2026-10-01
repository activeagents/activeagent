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
    assert_includes html, "4/10 passed", "the big percent carries its fraction on the same tile"
    assert_includes html, %(<div class="value tone-error">40%</div>)
    assert_includes html, "5 fix items"
    assert_includes html, "judged by rules", "a pass-rate ranking is not a judge — the dashboard reads it the same way"
    assert_includes html, "judge's pick"
    assert_not_includes html, "Winner"
    assert_includes html, %(<span class="name">llama-3.1-8b</span><span class="provider">openrouter/meta-llama</span>)
    assert_includes html, %(<span class="ratio tone-error">1/5 · 20%</span>), "a fraction always carries its percent"
    assert_includes html, %(<span class="ratio tone-error">3/5 · 60%</span>)
    assert_includes html, "expected tool not called ×3"
    assert_includes html, "<b>2.5s</b>"
    assert_includes html, "<b>900ms</b>"
    # gpt-5-mini's cost covers 1 of its 5 replays, so the sum is a lower
    # bound and reads as an estimate.
    assert_includes html, "<b>~$0.0012</b>"
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

  def test_html_reads_models_then_the_scenario_results_then_what_to_fix
    html = report(tool_resolver: resolver, links: LINKS).to_html
    heads = [ "Models", "Scenarios", "Details", "What to fix" ].map { |name| html.index(%(<span class="micro">#{name}</span>)) }

    assert_not_includes heads, nil, "every section renders"
    assert_equal heads.sort, heads, "What to fix follows the scenario matrix and the per-scenario details"
  end

  def test_markdown_reads_models_then_the_scenario_results_then_the_recommendations
    markdown = report.to_markdown
    heads = [ "| Model |", "| Scenario |", "## Answers", "## Recommendations" ].map { |head| markdown.index(head) }

    assert_not_includes heads, nil, "every section renders"
    assert_equal heads.sort, heads, "the recommendations follow the scenario matrix and the answers"
  end

  def test_markdown_sets_the_recommendations_off_by_one_blank_line_and_ends_with_a_newline
    markdown = report.to_markdown

    assert_includes markdown, "\n\n## Recommendations\n", "a blank line precedes the recommendations"
    assert_not_includes markdown, "\n\n\n## Recommendations", "only one blank line precedes the recommendations"
    assert markdown.end_with?("\n"), "the report ends with a newline"
  end

  def test_html_matrix_colors_calls_against_expectations_and_links_to_the_details
    html = report.to_html

    assert_includes html, %(<span class="group-name">desk</span><span class="count">3 scenarios</span>)
    assert_includes html, %(<span class="group-pass">1/3 · 33% passed</span><span class="group-pass">2/3 · 67% passed</span>)
    assert_includes html, %(<span class="group-pass text-error">0/1 · 0% passed</span><span class="group-pass text-success">1/1 · 100% passed</span>)
    assert_includes html, %(<span class="expect">index_status</span>)
    assert_includes html, %(<span class="g tone-success">[+]</span><span class="s tone-success">100%</span>)
    assert_includes html, %(<span class="g tone-error">[!]</span><span class="s tone-error">50%</span><span class="f">tool error</span>)
    assert_includes html, %(<span class="call-hit">inbox_status</span><span>check_async</span>)
    assert_includes html, %(<span class="call-err">index_status ✗ ×2</span>)
    assert_includes html, "no tools called"
    assert_includes html, %(<a href="#scenario-s_history">s_history</a>)
    assert_includes html, %(<div id="scenario-s_history">)
    assert_includes html, "<details>"
    assert_includes html, %(<span class="badge success">passed · 100%</span>)
    assert_includes html, %(<span class="badge error">failed · 50%</span>)
    assert_includes html, "2.5s · 89 tokens · $0.0012", "a reported cost carries no estimate mark"
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
    assert_includes html, %(<div class="value tone-error">—</div><div class="sub">0/0 passed</div>), "nothing scored reads as a dash"
    assert_includes html, "nothing priced"
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

  def test_html_reads_the_comparison_across_and_filters_the_fixes_by_model
    html = report.to_html

    # One row per model, best first: passed, mean score, latency, tokens per
    # scenario, cost per scenario and the typical fault with its diagnosis.
    table = html[%r{<div class="compare">(.*?)</table></div>}m, 1]
    assert table, "the models panel leads with the comparison table"
    assert_includes table, "<th class=\"fault\">Typical fault</th>"
    rows = table.scan(%r{<td class="model-cell"><span class="name">([^<]+)</span>})
    assert_equal [ [ "llama-3.1-8b" ], [ "gpt-5-mini" ] ].sort, rows.sort
    assert_match(%r{<tr>\s*<td class="model-cell"><span class="name">llama-3.1-8b</span>.*?3/5.*?gpt-5-mini}m, table, "the higher pass rate leads")
    assert_includes table, "★ pick"
    assert_includes table, "/scenario</span>"
    assert_match(/expected tool not called ×\d+ <span class="detail">· s_\w+: /, table)

    # The fix cards carry their models, and a chip per model narrows the list
    # through the stylesheet alone — the page still ships no script.
    assert_includes html, %(<input type="radio" name="fix-model" value="all" checked>)
    assert_includes html, %(<input type="radio" name="fix-model" value="m0">)
    assert_match(/<div class="fix" data-models="m[01]( m[01])?">/, html)
    assert_includes html, %(.fix-section:has(input[value="m0"]:checked) .fix[data-models]:not([data-models~="m0"]) { display: none; })
    assert_not_includes html, "<script"
  end

  # gpt-5-mini's replays carry a cost on 1 of 5 scenarios, llama's on none:
  # a partial sum is an estimate (a lower bound) and reads with the "~" the
  # legend explains, never with a "k of n priced" aside.
  def test_a_partially_priced_model_reads_as_an_estimate_with_the_legend
    summary = report.summary_by_model
    assert_equal [ 1, 1, 0, 0.0012 ], summary[gpt.label].values_at("priced", "reported", "estimated", "cost")
    assert_equal [ 0, 0, 0, nil ], summary[llama.label].values_at("priced", "reported", "estimated", "cost")

    html = report.to_html
    table = html[%r{<div class="compare">(.*?)</table></div>}m, 1]
    gpt_row = table[%r{<tr>\s*<td class="model-cell"><span class="name">gpt-5-mini</span>.*?</tr>}m]
    assert_includes gpt_row, %(~$0.0012<span class="per">~$0.0012/scenario</span>)
    llama_row = table[%r{<tr>\s*<td class="model-cell"><span class="name">llama-3.1-8b</span>.*?</tr>}m]
    assert_includes llama_row, %(<td class="num">—</td>)
    assert_not_includes html, "scenarios priced"
    assert_includes html, "cost <b>~$0.0012</b></span>"
    assert_includes html, %(<span class="legend">~ estimated from tokens × model rates</span>)
    assert_equal 1, html.scan("~ estimated from tokens × model rates").size, "the legend appears once"
  end

  # --- costs from the replay metadata -----------------------------------------

  RATE = { "input" => 5.0, "output" => 30.0, "source" => "catalog" }.freeze

  # Two scenarios under two models, every replay priced: gpt's reported by
  # the caller, llama's estimated from tokens at RATE, with the judge's spend
  # on each result in the metadata and the verdict's handed in at run level.
  def costed_report(**options)
    inbox = scenario("s_inbox", "Is the support inbox receiving email?", group: "desk", tools: [ "inbox_status" ])
    order = scenario("s_order", "Where is order ABC-123?", group: "orders", tools: [ "lookup_order" ])
    judge = ->(cost) { { "calls" => 1, "input_tokens" => 400, "output_tokens" => 20, "cost" => cost, "model" => "judge-1", "by_kind" => { "score" => 1 }, "source" => "traces" } }
    results = [
      result(inbox, gpt, replay(answer: "All healthy.", tool_calls: [ { "name" => "inbox_status" } ], input_tokens: 80, output_tokens: 9, cost: 0.0012,
                                metadata: { "cost_source" => "reported", "judge_usage" => judge.call(0.001) })),
      result(inbox, llama, replay(answer: "Healthy.", tool_calls: [ { "name" => "inbox_status" } ], input_tokens: 2_328, output_tokens: 423, cost: 0.02433,
                                  metadata: { "cost_source" => "estimated", "cost_rate" => RATE, "judge_usage" => judge.call(0.0015) })),
      result(order, gpt, replay(answer: "Order ABC-123 shipped.", tool_calls: [ { "name" => "lookup_order" } ], input_tokens: 100, output_tokens: 20, cost: 0.002,
                                metadata: { "cost_source" => "reported" })),
      result(order, llama, replay(answer: "", error: "boom", input_tokens: 0, output_tokens: 0, cost: 0.0,
                                  metadata: { "cost_source" => "no_usage" }), score: nil)
    ]
    run_usage = { "calls" => 1, "input_tokens" => 900, "output_tokens" => 60, "cost" => 0.004, "model" => "judge-1", "by_kind" => { "verdict" => 1 }, "source" => "meter" }
    Report.new(results: results, models: models, metadata: { "run" => 9, "judge_trace_ids" => %w[t1 t2], "sandbox" => { "id" => 1 } },
               judge_usage: run_usage, release: { "digest" => "abc123def456", "revision" => "deploy-7" }, **options)
  end

  def test_model_summaries_count_reported_and_estimated_replays_and_the_judges_spend_apart
    summary = costed_report.summary_by_model

    assert_equal [ 2, 2, 0, 0.0032, 0.001, 1 ], summary[gpt.label].values_at("priced", "reported", "estimated", "cost", "judge_cost", "judge_calls")
    # An errored replay with no tokens is priced at $0.00: neither reported nor estimated.
    assert_equal [ 2, 0, 1, 0.02433, 0.0015, 1 ], summary[llama.label].values_at("priced", "reported", "estimated", "cost", "judge_cost", "judge_calls")
  end

  def test_scenario_costs_sum_each_scenario_across_models_with_the_judge_apart
    costs = costed_report.scenario_costs

    assert_equal %w[s_inbox s_order], costs.keys
    inbox = costs["s_inbox"]
    assert_in_delta 0.02553, inbox["cost"], 1e-9
    assert_in_delta 0.0025, inbox["judge_cost"], 1e-9
    assert_in_delta 0.02803, inbox["total"], 1e-9
    assert inbox["estimated"], "one model's cost was estimated"
    assert_equal({ "cost" => 0.02433, "judge_cost" => 0.0015, "cost_source" => "estimated" }, inbox["models"][llama.label])
    order = costs["s_order"]
    assert_equal [ 0.002, nil, 0.002, false ], order.values_at("cost", "judge_cost", "total", "estimated")
    assert_equal "no_usage", order["models"][llama.label]["cost_source"]
  end

  def test_judge_usage_sums_every_results_calls_with_the_run_level_part_kept_apart
    usage = costed_report.judge_usage

    assert_equal 3, usage["calls"]
    assert_equal 1_700, usage["input_tokens"]
    assert_equal 100, usage["output_tokens"]
    assert_in_delta 0.0065, usage["cost"], 1e-9
    assert_equal "judge-1", usage["model"]
    assert_equal({ "score" => 2, "verdict" => 1 }, usage["by_kind"])
    assert usage["estimated"], "a cost priced from traces or a meter is an estimate"
    assert_equal({ "calls" => 1, "cost" => 0.004, "by_kind" => { "verdict" => 1 } }, usage["run"])
    assert_nil report.judge_usage, "no judge usage anywhere reads as none"
  end

  def test_run_costs_total_the_agent_and_the_judge_and_say_when_any_part_is_estimated
    costs = costed_report.run_costs

    assert_in_delta 0.02753, costs["cost"], 1e-9
    assert_in_delta 0.0065, costs["judge_cost"], 1e-9
    assert_in_delta 0.03403, costs["total"], 1e-9
    assert costs["estimated"]
    assert_equal [ 4, 0 ], costs.values_at("priced", "unpriced")
    assert_equal({ "cost" => nil, "judge_cost" => nil, "total" => nil, "estimated" => false, "priced" => 0, "unpriced" => 0 },
                 Report.new(results: [], models: models).run_costs)
  end

  def test_to_h_carries_the_release_and_the_judge_usage_only_when_there_are_any
    plain = report.to_h
    assert_equal %w[models criteria recommendations verdict metadata results], plain.keys
    assert plain["results"].none? { |result| result.key?("judge_usage") }
    assert_equal plain.to_json, report.to_json.then { |json| JSON.parse(json).to_json }, "nothing new leaks into the JSON"

    costed = costed_report.to_h
    assert_equal({ "digest" => "abc123def456", "revision" => "deploy-7" }, costed["release"])
    assert_equal 3, costed.dig("judge_usage", "calls")
    assert_equal({ "calls" => 1, "cost" => 0.004, "by_kind" => { "verdict" => 1 } }, costed.dig("judge_usage", "run"))
    assert_equal 1, costed["results"].first.dig("judge_usage", "calls"), "each result publishes its own judge usage"
    assert_equal 2, costed["models"][gpt.label]["reported"]
  end

  def test_html_renders_the_costs_with_the_estimate_mark_the_judge_and_the_legend_once
    html = costed_report.to_html

    # The cost tile totals agent and judge, apart underneath.
    assert_includes html, %(<div class="micro">Cost</div><div class="value">~$0.0340</div><div class="sub">agent ~$0.0275 · judge ~$0.0065</div>)
    # The comparison table gains a Judge column; the estimated cost carries its working.
    assert_includes html, %(<th class="num" title="What the judge spent scoring this model's answers">Judge</th>)
    assert_includes html, %(<td class="num" title="estimated: 2,328 in × $5.00/M + 423 out × $30.00/M · catalog rate">~$0.0243<span class="per">~$0.0122/scenario</span></td>)
    assert_includes html, %(<td class="num">$0.0032<span class="per">$0.0016/scenario</span></td>)
    assert_includes html, %(<td class="num">~$0.0010<span class="per">1 call</span></td>)
    # Each model block carries a judge line.
    assert_includes html, %(<span>judge <b>~$0.0015</b> · 1 call</span>)
    # The matrix: a cost line per cell, a trailing column per scenario and a group subtotal.
    assert_includes html, %(<div class="cost-line" title="estimated: 2,328 in × $5.00/M + 423 out × $30.00/M · catalog rate">~$0.0243 · judge ~$0.0015</div>)
    assert_includes html, %(<div class="cost-line">$0.0012 · judge ~$0.0010</div>)
    assert_includes html, %(<div class="cost-line">$0.00</div>), "an errored replay with no tokens cost nothing, and says so"
    assert_includes html, %(<span class="micro sm cost-head" title="What the scenario cost across every model, and what judging it cost">Cost</span>)
    assert_includes html, %(<span class="cost"><b>~$0.0255</b><span class="judge">judge ~$0.0025</span></span>)
    assert_includes html, %(<span class="cost"><b>$0.0020</b></span>)
    assert_includes html, "120px; }", "the grid reserves the trailing cost column"
    # The details meta names the judge's spend on the answer.
    assert_includes html, "$0.0012 · judge ~$0.0010</span>"
    # Header: scalar metadata only, the release, and the judge with its calls and spend.
    assert_includes html, %(<span class="chip"><b>release</b>abc123def456 · deploy-7</span>)
    assert_includes html, %(<span class="chip"><b>judge</b>rules · 3 calls · ~$0.0065</span>)
    assert_not_includes html, "judge_trace_ids"
    assert_not_includes html, %(<b>sandbox</b>)
    # Footer: the pass mark, the cost on both sides, and the legend once.
    assert_includes html, %(<span class="nowrap">pass ≥ 70%</span>)
    assert_includes html, %(<span class="nowrap">cost ~$0.0340 · agent ~$0.0275 · judge ~$0.0065</span>)
    assert_equal 1, html.scan("~ estimated from tokens × model rates").size
  end

  def test_markdown_renders_the_judge_column_the_matrix_cost_column_the_cost_per_answer_and_the_total
    markdown = costed_report.to_markdown

    assert_includes markdown, "| Model | Passed | Mean score | Mean latency | Tokens in/out | Cost | Judge | Faults |"
    assert_includes markdown, "| `gpt-5-mini` | 2/2 (100%) | 100% | — | 180/29 | $0.0032 | ~$0.0010 (1 call) | — |"
    assert_includes markdown, "| ~$0.0243 | ~$0.0015 (1 call) |"
    assert_includes markdown, "**Total: ~$0.0340** (agent ~$0.0275 · judge ~$0.0065)\n_~ estimated from tokens × model rates_\n"
    assert_includes markdown, "| Scenario | `gpt-5-mini` | `openrouter/meta-llama/llama-3.1-8b` | Cost |"
    assert_includes markdown, "| ✅ 100% | ✅ 100% | ~$0.0255 (judge ~$0.0025) |"
    assert_includes markdown, "| ✅ 100% | ⚠️ run error | $0.0020 |"
    assert_includes markdown, "### `s_inbox` · `openrouter/meta-llama/llama-3.1-8b` · passed · score 100% · ~$0.0243 · judge ~$0.0015"
    assert_includes markdown, "### `s_order` · `openrouter/meta-llama/llama-3.1-8b` · errored · $0.00"
  end

  def test_a_report_without_a_judge_has_no_judge_column_and_no_legend_when_every_cost_is_reported
    priced = results.map do |entry|
      Result.new(scenario: entry.scenario, spec: entry.spec, replay: Replay.new(**entry.replay.to_h.merge(cost: 0.001)),
                 scores: entry.scores, score: entry.score, status: entry.status, diagnosis: entry.diagnosis)
    end
    html = Report.new(results: priced, models: models).to_html
    markdown = Report.new(results: priced, models: models).to_markdown

    assert_not_includes html, ">Judge</th>"
    assert_not_includes html, "~$", "every cost was reported, so nothing is marked as an estimate"
    assert_not_includes html, "estimated from tokens"
    assert_includes html, %(<div class="micro">Cost</div><div class="value">$0.0100</div><div class="sub">agent only · 10 scenario runs priced</div>)
    assert_includes markdown, "| Model | Passed | Mean score | Mean latency | Tokens in/out | Cost | Faults |"
    assert_includes markdown, "**Total: $0.0100** (agent $0.0100)\n\n**Best model"
  end

  def test_html_of_a_single_model_run_has_no_comparison_table_or_filter
    html = report(models: models.first(1), results: results.select { |r| r.label == models.first.label }).to_html

    assert_not_includes html, %(class="compare")
    assert_not_includes html, %(name="fix-model")
  end
end
