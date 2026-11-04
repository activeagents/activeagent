# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"
require "cgi"

class EvalsReportTest < ActiveSupport::TestCase
  include EvalsTestSupport

  LINKS = { "mcp" => "/activeagents/mcp/%{key}", "tools" => "/activeagents/tools", "instructions" => "/activeagents/agents/1/edit" }.freeze
  SERVERS = {
    "index_status" => { "key" => "help_desk_status", "name" => "Help Desk Status", "status" => "enabled" },
    "lookup_order" => { "key" => "order_desk", "name" => "Order Desk", "status" => "available" },
    "refund_order" => { "key" => "order_desk", "name" => "Order Desk", "status" => "available" }
  }.freeze

  def resolver
    ->(name) { SERVERS[name] }
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

  # The page as a reader sees it: without the Markdown the copy buttons
  # carry and the script that copies it.
  def visible(html)
    html.gsub(%r{<textarea class="md-store".*?</textarea>}m, "").gsub(%r{<script>.*?</script>}m, "")
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

    assert_equal %w[models criteria recommendations verdict comparison metadata results], parsed.keys
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
    assert_equal [ "<script>" ], html.scan(/<script[^>]*>/), "one inline script, the copy buttons', and nothing loaded"
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

  def test_html_copies_each_piece_as_the_markdown_the_report_writes
    report = report(tool_resolver: resolver, links: LINKS)
    html = report.to_html
    store = ->(id) { CGI.unescapeHTML(html[%r{<textarea class="md-store" id="#{id}" hidden readonly>(.*?)</textarea>}m, 1].to_s) }

    assert_equal report.to_markdown, store.call("md-report")
    assert_equal report.verdict_markdown, store.call("md-verdict")
    assert_equal report.fix_items_markdown, store.call("md-fixes")
    assert_equal report.fix_items_markdown(model: "gpt-5-mini"), store.call("md-fixes-m0")
    assert_equal report.fix_item_markdown(report.fix_items.first), store.call("md-fix-0")
    assert_equal report.scenario_markdown("s_order", answer_limit: ActiveAgent::Evals::ReportHtml::ANSWER_LIMIT), store.call("md-scenario-s_order")
    assert_includes html, %(<button type="button" class="copy-md" data-md="md-report" title="Copy the whole report as GitHub-flavored Markdown">Copy as Markdown</button>)
    assert_includes html, %(data-md="md-fixes" data-md-model)
    assert_includes html, "navigator.clipboard.writeText"
    assert_includes html, %(document.execCommand("copy")), "the copy falls back where the Clipboard API is refused"
    assert_not_includes html, "<img src=x", "the embedded Markdown is escaped too"
  end

  def test_markdown_reads_models_then_the_scenario_results_then_what_to_fix
    markdown = report.to_markdown
    heads = [ "| Model |", "**Best model", "| Scenario |", "## Answers", "## What to fix" ].map { |head| markdown.index(head) }

    assert_not_includes heads, nil, "every section renders"
    assert_equal heads.sort, heads, "what to fix follows the scenario matrix and the answers, as on the HTML page"
  end

  def test_markdown_sets_what_to_fix_off_by_one_blank_line_and_ends_with_a_newline
    markdown = report.to_markdown

    assert_includes markdown, "</details>\n\n## What to fix\n", "a blank line precedes what to fix"
    assert_not_includes markdown, "\n\n\n## What to fix", "only one blank line precedes what to fix"
    assert markdown.end_with?("\n"), "the report ends with a newline"
    assert_not_includes markdown, "\n\n\n", "no section leaves a double blank line"
  end

  def test_markdown_folds_each_scenarios_answers_into_a_details_block
    markdown = report.to_markdown
    block = markdown[%r{<details>\n<summary><code>s_order</code>.*?</details>}m]

    assert_equal report.results.map { |result| result.scenario.key }.uniq.size, markdown.scan("<details>\n<summary>").size
    assert block, "one block per scenario"
    assert_includes block, "<summary><code>s_order</code> Where is order &lt;b&gt;ABC-123&lt;/b&gt;? — ❌ gpt-5-mini · ❌ openrouter/meta-llama/llama-3.1-8b</summary>\n\n**Prompt**",
                    "the summary escapes HTML and a blank line lets GitHub render the Markdown inside"
    assert_includes block, "| Model | Status | Score | Tools | Fault | Cost |"
    assert_includes block, "| `openrouter/meta-llama/llama-3.1-8b` | ❌ failed | 50% | — | missing capability | — |"
    assert_includes block, "> &lt;img src=x onerror=alert(1)&gt; no such order", "an answer cannot open HTML inside the block"
    assert_includes block, "- Expects tools: `lookup_order`"
  end

  def test_markdown_escapes_pipes_and_line_breaks_in_table_cells
    piped = [ result(scenario("pipe_1", "Compare a | b\nand c"), gpt, replay(answer: "a | b", tool_calls: [ { "name" => "look|up" } ])) ]
    markdown = Report.new(results: piped, models: [ gpt ]).to_markdown

    assert_includes markdown, "| `pipe_1` Compare a \\| b and c | ✅ 100% |"
    assert_includes markdown, "| `gpt-5-mini` | ✅ passed | 100% | look\\|up | — |"
  end

  def test_markdown_pieces_read_as_they_do_in_the_report
    markdown = report.to_markdown
    item = report.fix_items.find { |entry| entry["kind"] == "instruction" }

    assert_includes markdown, report.fix_item_markdown(item, heading: "###")
    assert_includes report.fix_item_markdown(item), "> Use lookup_order for order questions."
    assert_includes report.fix_item_markdown(item), "judge suggestion"
    assert report.fix_items_markdown.start_with?("## What to fix\n\n### ")
    assert_includes report.verdict_markdown, "**Best model: openrouter/meta-llama/llama-3.1-8b**"
    assert_includes report.verdict_markdown, "### Comparison"
    assert_includes report.verdict_markdown, "| Model | Passed |"
    single = report.scenario_markdown("s_order")
    assert single.start_with?("### Scenario `s_order`\n\n**Prompt**")
    assert_not_includes single, "<details>"
    assert_raises(KeyError) { report.scenario_markdown("nope") }
  end

  def test_markdown_fix_items_narrow_to_one_model
    only_gpt = report.fix_items_markdown(model: "gpt-5-mini")

    assert only_gpt.start_with?("## What to fix for `gpt-5-mini`")
    assert_includes only_gpt, "expected tool not called"
    assert_not_includes only_gpt, "tool error"
    assert_includes Report.new(results: results.select(&:passed?), models: models).fix_items_markdown, "_Nothing to fix._"
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
    html = visible(report.to_html)

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
    html = visible(Report.new(results: [], models: models).to_html)

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
    # through the stylesheet alone — the page's only script is the copy buttons'.
    assert_includes html, %(<input type="radio" name="fix-model" value="all" checked>)
    assert_includes html, %(<input type="radio" name="fix-model" value="m0">)
    assert_match(/<div class="fix" data-models="m[01]( m[01])?">/, html)
    assert_includes html, %(.fix-section:has(input[value="m0"]:checked) .fix[data-models]:not([data-models~="m0"]) { display: none; })
  end

  # gpt-5-mini's replays carry a cost on 1 of 5 scenarios, llama's on none:
  # a partial sum is an estimate (a lower bound) and reads with the "~" the
  # legend explains, never with a "k of n priced" aside.
  def test_a_partially_priced_model_reads_as_an_estimate_with_the_legend
    summary = report.summary_by_model
    assert_equal [ 1, 1, 0, 0.0012 ], summary[gpt.label].values_at("priced", "reported", "estimated", "cost")
    assert_equal [ 0, 0, 0, nil ], summary[llama.label].values_at("priced", "reported", "estimated", "cost")

    html = visible(report.to_html)
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
    assert_equal %w[models criteria recommendations verdict comparison metadata results], plain.keys
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
    html = visible(costed_report.to_html)

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

    assert_includes markdown, "| Model | Passed | Mean score | Mean latency | Median / P95 | Tokens in/out | Cost | Cost / 1,000 | Judge | Faults |"
    assert_includes markdown, "| `gpt-5-mini` | 2/2 (100%) | 100% | — | — | 180/29 | $0.0032 | $1.6000 | ~$0.0010 (1 call) | — |"
    assert_includes markdown, "| ~$0.0243 | ~$12.1650 | ~$0.0015 (1 call) |", "an estimated cohort reads its rate per 1,000 as an estimate"
    assert_includes markdown, "**Total: ~$0.0340** (agent ~$0.0275 · judge ~$0.0065)\n_~ estimated from tokens × model rates_\n"
    assert_includes markdown, "| Scenario | `gpt-5-mini` | `openrouter/meta-llama/llama-3.1-8b` | Cost |"
    assert_includes markdown, "| ✅ 100% | ✅ 100% | ~$0.0255 (judge ~$0.0025) |"
    assert_includes markdown, "| ✅ 100% | ⚠️ run error | $0.0020 |"
    assert_includes markdown, "| `openrouter/meta-llama/llama-3.1-8b` | ✅ passed | 100% | inbox_status | — | ~$0.0243 · judge ~$0.0015 |"
    assert_includes markdown, "| `openrouter/meta-llama/llama-3.1-8b` | ⚠️ errored | — | — | run error | $0.00 |"
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
    assert_includes markdown, "| Model | Passed | Mean score | Mean latency | Median / P95 | Tokens in/out | Cost | Cost / 1,000 | Faults |"
    assert_includes markdown, "**Total: $0.0100** (agent $0.0100)\n\n**Best model"
  end

  def test_latency_reads_at_the_median_and_the_95th_percentile_beside_the_mean
    timed = [ 400, 100, 300, 200 ].each_with_index.map do |ms, i|
      Result.new(scenario: scenario("s_#{i}"), spec: gpt, replay: replay(duration_ms: ms), scores: {}, score: 1.0, status: "passed")
    end
    untimed = Result.new(scenario: scenario("s_0"), spec: llama, replay: replay, scores: {}, score: 1.0, status: "passed")
    report = Report.new(results: timed + [ untimed ], models: models)

    assert_equal [ 250, 200, 400 ], report.summary_by_model[gpt.label].values_at("avg_duration_ms", "p50_duration_ms", "p95_duration_ms")
    assert_equal [ nil, nil ], report.summary_by_model[llama.label].values_at("p50_duration_ms", "p95_duration_ms")
    assert_includes report.to_markdown, "| 250 ms | 200 / 400 ms |"
    html = report.to_html
    assert_includes html, %(<td class="num">200ms / 400ms</td>)
    assert_includes html, "<span>p50 / p95 <b>200ms / 400ms</b></span>"
    assert_includes html, "<span>p50 / p95 <b>—</b></span>", "a model with no timed replay reads as missing"
  end

  def test_a_comparing_report_carries_the_comparison_of_its_results
    comparison = report.comparison

    assert_equal ActiveAgent::Evals::Comparison.new(results: results, models: models).to_h, comparison
    assert_equal comparison, report.to_h["comparison"]
    assert_equal [ llama.label, gpt.label ], comparison["ranking"]
    assert_equal [ 40.0, [ 0.0, 80.0 ], false ], comparison["pairs"].sole.values_at("difference", "interval", "decisive")
  end

  def test_a_single_model_report_has_no_comparison
    single = report(models: models.first(1), results: results.select { |result| result.label == gpt.label })

    assert_nil single.comparison
    assert_not single.to_h.key?("comparison")
    assert_not_includes single.to_markdown, "## Comparison"
  end

  def test_a_recorded_comparison_is_rendered_instead_of_resampling
    recorded = { method: { resamples: 5_000, confidence: 0.95, seed: 0 }, ranking: [ gpt.label, llama.label ],
                 models: { gpt.label => { scenarios: 5, pass_rate: 20.0, interval: [ 0.0, 60.0 ] },
                           llama.label => { scenarios: 5, pass_rate: 60.0, interval: [ 20.0, 100.0 ] } },
                 pairs: [], conclusion: "Recorded." }
    rebuilt = report(comparison: recorded)

    assert_equal "Recorded.", rebuilt.comparison["conclusion"]
    assert_equal [ gpt.label, llama.label ], rebuilt.to_h.dig("comparison", "ranking"), "the recorded ranking, with string keys"
    assert_includes rebuilt.to_markdown, "\nRecorded.\n"
    assert_includes rebuilt.to_markdown, "| `gpt-5-mini` | 20.0% | 0.0 to 60.0 | 5 |", "nested keys are read as strings too"
    assert_nil report(models: models.first(1), results: results.first(1), comparison: recorded).comparison,
               "a single-model report compares nothing, whatever it is handed"
  end

  def test_markdown_compares_the_models_between_the_summary_and_the_matrix
    markdown = report.to_markdown
    section = markdown[/## Comparison\n.*?\n_95% CI.*?_\n/m]

    assert section, "the comparison renders as one section"
    assert_operator markdown.index("**Best model"), :<, markdown.index("## Comparison")
    assert_operator markdown.index("## Comparison"), :<, markdown.index("| Scenario |")
    assert_includes section, "| Model | Pass rate | 95% CI | Scenarios |"
    assert_includes section, "| `openrouter/meta-llama/llama-3.1-8b` | 60.0% | 20.0 to 100.0 | 5 |\n| `gpt-5-mini` | 20.0% | 0.0 to 60.0 | 5 |"
    assert_includes section, "| `openrouter/meta-llama/llama-3.1-8b` vs `gpt-5-mini` | +40.0 points | 0.0 to 80.0 | 5 | no |"
    assert_includes section, "\nThe pairwise difference interval includes zero: the ranking is not decisive evidence of superiority.\n"
    assert_includes section, "_95% CI from 5,000 resamples of whole scenarios (seed 0)._"
  end

  def test_markdown_writes_a_dash_where_there_were_too_few_scenarios_for_an_interval
    markdown = report(results: results.select { |result| result.scenario.key == "s_inbox" }).to_markdown

    assert_includes markdown, "| `gpt-5-mini` | 100.0% | — | 1 |"
    assert_includes markdown, "| — | 1 | no |"
    assert_includes markdown, "\nThe models share too few scenarios to compare.\n"
  end

  def test_markdown_writes_a_dash_for_a_model_with_no_results
    markdown = report(results: results.select { |result| result.label == gpt.label }).to_markdown

    assert_includes markdown, "| `openrouter/meta-llama/llama-3.1-8b` | — | — | 0 |"
    assert_includes markdown, "| `gpt-5-mini` vs `openrouter/meta-llama/llama-3.1-8b` | — | — | 0 | no |"
  end

  def test_html_plots_each_models_interval_best_first_with_the_conclusion_under_it
    html = report.to_html
    plot = html[%r{<div class="intervals">(.*?)</div>\n</div>}m, 1].to_s

    assert_includes plot, %(<div class="micro sm">Pass rate · 95% CI</div>)
    names = plot.scan(%r{<span class="iv-name">([^<]+)</span>}).flatten
    assert_equal %w[llama-3.1-8b gpt-5-mini], names, "best first, as the comparison ranks them"
    assert_includes plot, %(<span class="iv-range" style="left:20.0%;width:80.0%"></span><span class="iv-point" style="left:60.0%"></span>)
    assert_includes plot, %(<span class="iv-figures"><b>60.0%</b> 20.0 to 100.0 · 5 scenarios</span>)
    assert_includes plot, %(<span class="iv-tick" style="left:50%">50%</span>)
    assert_includes plot, %(<p class="iv-conclusion">The pairwise difference interval includes zero: the ranking is not decisive evidence of superiority.</p>)
    assert_includes plot, %(<p class="iv-caption">95% CI from 5,000 resamples of whole scenarios</p>)
    assert_operator html.index(%(<div class="compare">)), :<, html.index(%(<div class="intervals">)), "the plot follows the comparison table"
  end

  def test_html_plot_draws_no_range_where_there_were_too_few_scenarios
    html = report(results: results.select { |result| result.scenario.key == "s_inbox" }).to_html

    assert_includes html, %(<span class="iv-track"><span class="iv-point" style="left:100.0%"></span></span><span class="iv-figures"><b>100.0%</b> no interval · 1 scenario</span>)
    assert_includes html, %(<p class="iv-conclusion">The models share too few scenarios to compare.</p>)
  end

  # A row of its own would size its figures column to its own text, giving
  # each track, and the axis under them, a different width.
  def test_html_plot_rows_and_axis_share_one_grid_so_the_ticks_line_up_with_the_dots
    html = report.to_html

    assert_match(/\.intervals \{[^}]*display: grid; grid-template-columns: minmax\(120px, 200px\) minmax\(160px, 1fr\) minmax\(190px, auto\);/, html)
    assert_includes html, ".iv-row { display: contents; }"
    assert_no_match(/\.iv-row \{[^}]*grid-template-columns/, html)
    assert_includes html, ".intervals > .micro, .iv-conclusion, .iv-caption { grid-column: 1 / -1; }"
    assert_includes html, "@media (max-width: 640px) { .intervals { grid-template-columns: minmax(0, 1fr);"
  end

  def test_html_plot_renders_a_recorded_comparison_and_escapes_it
    recorded = report.comparison.merge("conclusion" => "<b>Recorded</b>.")

    assert_includes report(comparison: recorded).to_html, %(<p class="iv-conclusion">&lt;b&gt;Recorded&lt;/b&gt;.</p>)
  end

  def test_html_of_a_single_model_run_has_no_comparison_table_or_filter
    html = visible(report(models: models.first(1), results: results.select { |r| r.label == models.first.label }).to_html)

    assert_not_includes html, %(class="compare")
    assert_not_includes html, %(name="fix-model")
    assert_not_includes html, %(<div class="intervals">)
  end

  # --- pass gates --------------------------------------------------------------

  def test_summary_by_group_counts_each_models_results_per_group_in_run_order
    summary = gated_report.summary_by_group

    assert_equal %w[orders help experimental], summary.keys
    assert_equal [ "Order support", "Product help", "Experimental" ], summary.values.map { |group| group["name"] }
    assert_equal({ "scenarios" => 2, "passed" => 1, "errored" => 0, "pass_rate" => 50.0, "avg_score" => 0.75, "faults" => { "low_quality" => 1 } },
                 summary.dig("orders", "models", gpt.label))
    assert_equal({ "scenarios" => 2, "passed" => 2, "errored" => 0, "pass_rate" => 100.0, "avg_score" => 1.0, "faults" => {} },
                 summary.dig("orders", "models", llama.label))
    assert_equal [ gpt.label ], summary.dig("help", "models").keys, "a model with no result in a group is absent"
    assert_equal [ 1, 0, 1, 0.0, nil, { "run_error" => 1 } ], summary.dig("experimental", "models", llama.label).values
    assert_equal "desk", report.summary_by_group.dig("desk", "name"), "a group without a display name reads as its key"
    assert_equal({}, Report.new(results: [ gated_results.last ], models: models).summary_by_group, "an ungrouped scenario is in no group")
  end

  def test_gates_cover_each_group_and_model_then_the_whole_report_over_the_gated_results
    gates = gated_report.gates

    assert_equal [ %w[orders gpt-5-mini], [ "orders", llama.label ], %w[help gpt-5-mini], %w[experimental gpt-5-mini],
                   [ "experimental", llama.label ], [ nil, "gpt-5-mini" ], [ nil, llama.label ] ],
                 gates.map { |gate| [ gate.group, gate.label ] }
    orders_gpt, orders_llama, help_gpt, experimental_gpt, experimental_llama, all_gpt, all_llama = gates
    counts = ->(gate) { gate.to_h.values_at("name", "passed", "total", "pass_rate", "min_pass_rate", "gated", "met") }

    assert_equal [ "Order support", 1, 2, 0.5, 1.0, true, false ], counts.call(orders_gpt)
    assert_equal [ "Order support", 2, 2, 1.0, 1.0, true, true ], counts.call(orders_llama)
    assert_equal [ "Product help", 1, 1, 1.0, 0.8, true, true ], counts.call(help_gpt)
    assert_equal [ "Experimental", 0, 1, 0.0, 0.8, false, true ], counts.call(experimental_gpt), "an ungated group's gate is always met"
    assert_equal [ "Experimental", 0, 1, 0.0, 0.8, false, true ], counts.call(experimental_llama)
    assert_equal [ "All", 3, 4, 0.75, 0.8, true, false ], counts.call(all_gpt),
                 "the whole-report row leaves out the ungated group and counts the ungrouped scenario"
    assert_equal [ "All", 2, 2, 1.0, 0.8, true, true ], counts.call(all_llama)
    assert gates.none? { |gate| gate.total.zero? }

    assert_equal "Order support · gpt-5-mini: 1/2 (50%) passed, below 100%", orders_gpt.to_s
    assert_equal "Order support · #{llama.label}: 2/2 (100%) passed, at or above 100%", orders_llama.to_s
    assert_equal "Experimental · gpt-5-mini: 0/1 (0%) passed, not gated", experimental_gpt.to_s
    assert_equal "All · gpt-5-mini: 3/4 (75%) passed, below 80%", all_gpt.to_s
    assert_equal({ "group" => "orders", "name" => "Order support", "label" => "gpt-5-mini", "passed" => 1, "total" => 2, "pass_rate" => 0.5,
                   "min_pass_rate" => 1.0, "gated" => true, "met" => false }, orders_gpt.to_h)
  end

  def test_passed_asks_every_gate_and_other_bars_can_be_tried_on_the_same_report
    report = gated_report

    assert_not report.passed?
    assert_equal [ %w[orders gpt-5-mini], [ nil, "gpt-5-mini" ] ], report.gates.reject(&:met?).map { |gate| [ gate.group, gate.label ] }

    lenient = PassThresholds.new(suite: { "min_pass_rate" => 0.5 }, groups: { "experimental" => { "gated" => false } })
    assert report.passed?(lenient)
    assert_equal 0.5, report.gates(lenient).first.min_pass_rate

    strict = report.gates(PassThresholds.default)
    assert_equal 7, strict.size
    assert strict.all?(&:gated), "the defaults gate every group"
    assert_equal [ [ nil, "gpt-5-mini", 3, 5 ], [ nil, llama.label, 2, 3 ] ],
                 strict.last(2).map { |gate| [ gate.group, gate.label, gate.passed, gate.total ] }
    assert_not Report.new(results: gated_results, models: models).passed?, "without bars, every scenario has to pass"
    assert Report.new(results: gated_results.select(&:passed?), models: models).passed?
    assert_not Report.new(results: [], models: models).passed?, "no results, no gate, nothing shown"
  end

  def test_failures_list_what_did_not_pass_in_run_order_and_narrow_to_a_group
    report = gated_report

    assert_equal [ %w[order_status gpt-5-mini], %w[exp_1 gpt-5-mini], [ "exp_1", llama.label ] ],
                 report.failures.map { |result| [ result.scenario.key, result.label ] }
    assert_equal [ "exp_1", "exp_1" ], report.failures(group: "experimental").map { |result| result.scenario.key }
    assert_equal [ "order_status" ], report.failures(group: :orders).map { |result| result.scenario.key }
    assert_empty report.failures(group: "help")
  end

  def test_to_h_carries_the_bars_the_groups_and_the_gates_only_when_the_suite_declared_bars
    plain = Report.new(results: gated_results, models: models).to_h
    assert_equal %w[models criteria recommendations verdict comparison results], plain.keys

    gated = gated_report.to_h
    assert_equal %w[models criteria recommendations verdict comparison pass_thresholds groups gates results], gated.keys
    assert_equal THRESHOLDS.to_h, gated["pass_thresholds"]
    assert_equal gated_report.summary_by_group, gated["groups"]
    assert_equal gated_report.gates.map(&:to_h), gated["gates"]
    assert_equal gated.to_json, JSON.parse(gated_report.to_json).to_json, "the gates serialize as plain JSON"
    assert_equal false, JSON.parse(gated_report.to_json)["gates"].last(2).first["met"]
    assert_equal plain.except("pass_thresholds", "groups", "gates"), gated.except("pass_thresholds", "groups", "gates"),
                 "the bars change nothing else in the hash"
  end

  def test_to_h_names_the_threshold_the_answers_were_scored_at_when_an_explicit_one_wins
    report = Report.new(results: gated_results, models: models, threshold: 0.9, pass_thresholds: THRESHOLDS)

    assert_equal 0.9, report.to_h.dig("pass_thresholds", "threshold")
    assert_equal THRESHOLDS.to_h.except("threshold"), report.to_h["pass_thresholds"].except("threshold")
  end

  def test_markdown_tables_the_pass_rate_by_group_and_lists_the_failures
    report = gated_report
    table = report.gates_markdown

    assert_equal [ "## Pass rate by group", "", "| Group | Model | Passed | Pass rate | Bar | Mean score |", "|---|---|---|---|---|---|" ], table.first(4)
    assert_equal "| Order support | `gpt-5-mini` | 1 of 2 | 50% ❌ | 100% | 75% |", table[4]
    assert_equal "| Order support | `#{llama.label}` | 2 of 2 | 100% ✅ | 100% | 100% |", table[5]
    assert_equal "| Product help | `gpt-5-mini` | 1 of 1 | 100% ✅ | 80% | 100% |", table[6]
    assert_equal "| Experimental | `gpt-5-mini` | 0 of 1 | 0% — | not gated | 50% |", table[7]
    assert_equal "| Experimental | `#{llama.label}` | 0 of 1 | 0% — | not gated | — |", table[8]
    assert_equal "| All | `gpt-5-mini` | 3 of 4 | 75% ❌ | 80% | 80% |", table[9], "an All row's mean score is the model's over every result"
    assert_equal "| All | `#{llama.label}` | 2 of 2 | 100% ✅ | 80% | 100% |", table[10]
    assert_equal 11, table.size
    assert_includes report.gates_markdown(PassThresholds.default), "| Experimental | `gpt-5-mini` | 0 of 1 | 0% ❌ | 100% | 50% |"

    markdown = report.to_markdown
    assert_includes markdown, "\n## Pass rate by group\n\n| Group |"
    assert_operator markdown.index("| Model | Passed |"), :<, markdown.index("## Pass rate by group")
    assert_operator markdown.index("## Pass rate by group"), :<, markdown.index("**Best model")
    assert_not_includes markdown, "\n\n\n"
    assert_not_includes Report.new(results: gated_results, models: models).to_markdown, "Pass rate by group"
    assert_not_includes Report.new(results: [], models: models, pass_thresholds: THRESHOLDS).to_markdown, "Pass rate by group", "no results, no table"

    piped = grouped("pipe_1", "Compare a | b", "pipes", "Pipes | bars\nand more")
    piped_row = Report.new(results: [ result(piped, gpt, replay(answer: "a | b", tool_calls: [ { "name" => "inbox_status" } ])) ],
                           models: [ gpt ], pass_thresholds: THRESHOLDS).gates_markdown[4]
    assert_equal "| Pipes \\| bars and more | `gpt-5-mini` | 1 of 1 | 100% ✅ | 80% | 100% |", piped_row, "a group name is escaped like any cell"

    failures = report.failures_markdown
    assert_equal 3, failures.lines.size
    assert failures.start_with?("- `order_status` on `gpt-5-mini`: low quality — Scored 50% against a pass threshold of 70%"), failures
    assert_includes failures, "- `exp_1` on `#{llama.label}`: run error — The run failed before the agent answered: RuntimeError: provider down"
    assert_equal 2, report.failures_markdown(group: "experimental").lines.size
    assert_equal "_Nothing failed._", report.failures_markdown(group: "help")

    undiagnosed = Result.new(scenario: scenario("s_1", "Ping"), spec: gpt, replay: replay(answer: "", error: "timed out"), scores: {}, score: nil, status: "errored")
    assert_equal "- `s_1` on `gpt-5-mini`: errored — timed out", Report.new(results: [ undiagnosed ], models: [ gpt ]).failures_markdown
    unexplained = Result.new(scenario: scenario("f_1", "Ping"), spec: gpt, replay: replay(answer: "Pong."), scores: {}, score: 0.2, status: "failed")
    assert_equal "- `f_1` on `gpt-5-mini`: failed", Report.new(results: [ unexplained ], models: [ gpt ]).failures_markdown,
                 "a failed result without a diagnosis reads as its status"
  end

  def test_html_tones_each_group_row_by_its_gate_and_names_the_bar
    html = gated_report.to_html

    assert_includes html, %(<span class="group-name">Order support</span><span class="count">2 scenarios</span>) +
                          %(<span class="group-pass text-error" title="pass rate ≥ 100%">1/2 · 50% passed</span>) +
                          %(<span class="group-pass text-success" title="pass rate ≥ 100%">2/2 · 100% passed</span>)
    assert_includes html, %(<span class="group-pass text-success" title="pass rate ≥ 80%">1/1 · 100% passed</span><span class="group-pass">—</span>)
    assert_includes html, %(<span class="group-pass" title="not gated">0/1 · 0% passed</span><span class="group-pass" title="not gated">0/1 · 0% passed</span>)

    untoned = Report.new(results: gated_results, models: models).to_html
    assert_includes untoned, %(<span class="group-pass">1/2 · 50% passed</span><span class="group-pass text-success">2/2 · 100% passed</span>)
    assert_includes untoned, %(<span class="group-pass text-error">0/1 · 0% passed</span><span class="group-pass text-error">0/1 · 0% passed</span>)
    assert_not_includes untoned, "title=\"pass rate", "without bars the group rows read as they always did"
  end

  def test_a_model_whose_results_all_sit_in_an_ungated_group_has_no_all_row
    lookup = grouped("order_lookup", "Where is order ABC-123?", "orders", "Order support")
    experiment = grouped("exp_1", "Draft a reply in the customer's tone.", "experimental", "Experimental")
    called = [ { "name" => "inbox_status" } ]
    report = Report.new(results: [
      result(lookup, gpt, replay(answer: "It shipped on Monday.", tool_calls: called)),
      result(experiment, gpt, replay(answer: "Dear customer.", tool_calls: called), score: 0.5),
      result(experiment, llama, replay(answer: "Dear customer.", tool_calls: called), score: 0.5)
    ], models: models, pass_thresholds: THRESHOLDS)
    gates = report.gates

    assert_equal [ %w[orders gpt-5-mini], %w[experimental gpt-5-mini], [ "experimental", llama.label ], [ nil, "gpt-5-mini" ] ],
                 gates.map { |gate| [ gate.group, gate.label ] }
    assert gates.none? { |gate| gate.total.zero? }
    assert report.passed?
    assert_not report.passed?(PassThresholds.default), "gated, the experimental failures count"
  end

  def test_the_pass_thresholds_set_the_criterion_threshold_unless_one_is_given
    strict = PassThresholds.new(suite: { "threshold" => 0.9 })
    scored = Result.new(scenario: scenario("s_1", "Ping"), spec: gpt, replay: replay(answer: "Pong."), scores: { "quality" => 0.8 }, score: 0.8, status: "passed")
    build = ->(**options) { Report.new(results: [ scored ], models: [ gpt ], **options) }

    assert_equal 1, build.call.criterion_scores.dig("quality", "passed")
    assert_equal 0, build.call(pass_thresholds: strict).criterion_scores.dig("quality", "passed")
    assert_equal 1, build.call(pass_thresholds: strict, threshold: 0.7).criterion_scores.dig("quality", "passed"), "an explicit threshold wins"
    assert_includes build.call(pass_thresholds: strict).to_html, "pass ≥ 90%"
    assert_includes build.call.to_html, "pass ≥ 70%"
  end

  def test_html_group_rows_count_their_own_scenarios_when_a_group_is_split_or_has_a_name_but_no_key
    called = [ { "name" => "inbox_status" } ]
    first = grouped("order_lookup", "Where is order ABC-123?", "orders", "Order support")
    other = grouped("help_cancel", "How do I cancel my order?", "help", "Product help")
    second = grouped("order_status", "Has order ABC-123 shipped?", "orders", "Order support")
    named = Scenario.from_hash({ "key" => "named_only", "prompt" => "Hello?", "group_name" => "Named only", "expectations" => { "tools" => [ "inbox_status" ] } })
    results = [
      result(first, gpt, replay(answer: "It shipped on Monday.", tool_calls: called)),
      result(other, gpt, replay(answer: "From the order page.", tool_calls: called)),
      result(second, gpt, replay(answer: "Probably.", tool_calls: called), score: 0.5),
      result(named, gpt, replay(answer: "Yes.", tool_calls: called))
    ]
    rows = Report.new(results: results, models: [ gpt ]).to_html.scan(%r{<div class="mx group">.*?</div>})

    assert_equal 4, rows.size
    assert_includes rows[0], %(<span class="group-name">Order support</span><span class="count">1 scenario</span><span class="group-pass text-success">1/1 · 100% passed</span>)
    assert_includes rows[1], %(<span class="group-name">Product help</span><span class="count">1 scenario</span><span class="group-pass text-success">1/1 · 100% passed</span>)
    assert_includes rows[2], %(<span class="group-name">Order support</span><span class="count">1 scenario</span><span class="group-pass text-error">0/1 · 0% passed</span>)
    assert_includes rows[3], %(<span class="group-name">Named only</span><span class="count">1 scenario</span><span class="group-pass text-success">1/1 · 100% passed</span>)

    toned = Report.new(results: results, models: [ gpt ], pass_thresholds: THRESHOLDS).to_html
    assert_includes toned, %(<span class="group-name">Named only</span><span class="count">1 scenario</span><span class="group-pass text-success">1/1 · 100% passed</span>),
                    "a group with a name and no key has no gate, so its row reads by its counts"
    toned_rows = toned.scan(%r{<div class="mx group">.*?</div>})
    assert_includes toned_rows[0], %(<span class="group-pass text-success" title="pass rate ≥ 100%">1/1 · 100% passed</span>),
                    "a split group's row is toned by its own count against the group's bar"
    assert_includes toned_rows[2], %(<span class="group-pass text-error" title="pass rate ≥ 100%">0/1 · 0% passed</span>)
  end

  # --- trials ------------------------------------------------------------------

  # The five-scenario fixture with the inbox scenario replayed twice more
  # under gpt-5-mini: a second pass, then a wrong tool.
  def trial_results
    inbox = scenario("s_inbox", "Is the support inbox receiving email?", group: "desk", tools: [ "inbox_status" ])
    results + [
      result(inbox, gpt, replay(answer: "Still healthy.", tool_calls: [ { "name" => "inbox_status" } ], cost: 0.001), trial: 2),
      result(inbox, gpt, replay(answer: "The inbox is fine.", tool_calls: [ { "name" => "find_tickets" } ]), score: 0.5, trial: 3)
    ]
  end

  def trial_report(**options)
    report(results: trial_results, **options)
  end

  # Two desk scenarios replayed three times under gpt-5-mini and twice under
  # llama: gpt passes 2 of 3 inbox replays and 1 of 3 queue replays (a tool
  # error, then a wrong tool), llama fails both inbox replays and passes
  # both queue replays.
  def flaky_report
    inbox = scenario("s_inbox", "Is the support inbox receiving email?", group: "desk", tools: [ "inbox_status" ])
    queue = scenario("s_queue", "Is the reply queue backed up?", group: "desk", tools: [ "inbox_status" ])
    healthy = ->(cost = 0.001) { replay(answer: "All healthy.", tool_calls: [ { "name" => "inbox_status" } ], cost: cost) }
    wrong_tool = -> { replay(answer: "The inbox is fine.", tool_calls: [ { "name" => "find_tickets" } ], cost: 0.001) }
    broken_tool = replay(answer: "The check failed.", tool_calls: [ { "name" => "inbox_status", "error" => true, "detail" => "timeout" } ], cost: 0.001)
    unchecked = -> { replay(answer: "I cannot check that.") }
    Report.new(models: models, results: [
      result(inbox, gpt, healthy.call, trial: 1),
      result(inbox, gpt, healthy.call, trial: 2),
      result(inbox, gpt, wrong_tool.call, score: 0.5, trial: 3),
      result(queue, gpt, healthy.call, trial: 1),
      result(queue, gpt, broken_tool, score: 0.5, trial: 2),
      result(queue, gpt, wrong_tool.call, score: 0.5, trial: 3),
      result(inbox, llama, unchecked.call, score: 0.5, trial: 1),
      result(inbox, llama, unchecked.call, score: 0.5, trial: 2),
      result(queue, llama, healthy.call(nil), trial: 1),
      result(queue, llama, healthy.call(nil), trial: 2)
    ])
  end

  def test_model_summaries_count_every_replay_with_the_distinct_scenarios_beside_it
    assert_equal [ 5, 5, 1 ], report.summary_by_model[gpt.label].values_at("scenarios", "unique_scenarios", "passed")
    assert_equal 1, report.trials

    summary = trial_report.summary_by_model
    assert_equal [ 7, 5, 2, 28.6 ], summary[gpt.label].values_at("scenarios", "unique_scenarios", "passed", "pass_rate")
    assert_equal [ 5, 5, 3 ], summary[llama.label].values_at("scenarios", "unique_scenarios", "passed")
    assert_equal 3, trial_report.trials
    assert_equal [ 6, 2 ], flaky_report.summary_by_model[gpt.label].values_at("scenarios", "unique_scenarios")
  end

  def test_the_verdict_counts_replays_of_scenarios_only_when_a_model_replayed_them
    assert_match(/\APassed 3 of 5 scenarios \(60%\) with a mean score of 80%\.\z/, report.verdict["rationale"])
    assert_equal "Passed 3 of 6 replays of 2 scenarios (50%) with a mean score of 75% at $0.0060.", flaky_report.verdict["rationale"]
  end

  def test_the_matrix_cell_runs_the_trials_marks_together_with_their_mean_score_and_commonest_fault
    rows = flaky_report.to_markdown.lines

    assert_includes rows.find { |line| line.include?("`s_inbox`") }, "| ✅✅❌ 83% expected tool not called |"
    assert_includes rows.find { |line| line.include?("`s_queue`") }, "| ✅❌❌ 67% tool error | ✅✅ 100% |", "a tie between faults goes to the first trial's"
    assert_includes report.to_markdown, "| `s_inbox` Is the support inbox receiving email? | ✅ 100% | ✅ 100% | ~$0.0012 |"
  end

  def test_scenario_markdown_lists_each_trial_as_its_own_row_and_answer
    markdown = trial_report.scenario_markdown("s_inbox")
    rows = markdown.lines.select { |line| line.start_with?("| `") }

    assert_equal [ "| `gpt-5-mini` · trial 1 | ✅ passed | 100% | inbox_status | — | $0.0012 |",
                   "| `gpt-5-mini` · trial 2 | ✅ passed | 100% | inbox_status | — | $0.0010 |",
                   "| `gpt-5-mini` · trial 3 | ❌ failed | 50% | find_tickets | expected tool not called | — |",
                   "| `openrouter/meta-llama/llama-3.1-8b` | ✅ passed | 100% | inbox_status, check_async | — | — |" ], rows.map(&:chomp)
    assert_includes markdown, "**`gpt-5-mini` · trial 3** — ❌ failed\n\nFault: expected tool not called"
    assert_includes markdown, "**`openrouter/meta-llama/llama-3.1-8b`** — ✅ passed", "a model with one replay keeps its plain name"
    assert_includes markdown, "> Still healthy."
    assert_equal 4, markdown.scan("** — ").size, "one answer block per replay"
    assert_includes trial_report.to_markdown,
                    "<summary><code>s_inbox</code> Is the support inbox receiving email? — ✅✅❌ gpt-5-mini · ✅ openrouter/meta-llama/llama-3.1-8b</summary>",
                    "the folded summary runs a replayed model's marks together"
  end

  def test_failures_markdown_names_the_trial_of_each_failing_replay
    assert_equal [ "- `s_inbox` on `gpt-5-mini` · trial 3: expected tool not called — Expected inbox_status to be called; the agent called find_tickets.",
                   "- `s_queue` on `gpt-5-mini` · trial 2: tool error — Tool inbox_status returned an error while answering.",
                   "- `s_queue` on `gpt-5-mini` · trial 3: expected tool not called — Expected inbox_status to be called; the agent called find_tickets.",
                   "- `s_inbox` on `#{llama.label}` · trial 1: missing capability — The agent said it lacks the ability to perform this task.",
                   "- `s_inbox` on `#{llama.label}` · trial 2: missing capability — The agent said it lacks the ability to perform this task." ],
                 flaky_report.failures_markdown(group: "desk").lines(chomp: true)

    failures = trial_report.failures_markdown.lines(chomp: true)
    assert_includes failures, "- `s_inbox` on `gpt-5-mini` · trial 3: expected tool not called — Expected inbox_status to be called; the agent called find_tickets.",
                    "a replayed scenario names the trial even when only one replay failed"
    assert_includes failures, "- `s_queue` on `gpt-5-mini`: expected tool not called — Expected inbox_status to be called; the agent called find_tickets.",
                    "a scenario the model ran once keeps the plain line"
    assert_equal failures, trial_report.failures.map { |result| trial_report.failure_markdown(result) }, "failures_markdown is built from failure_markdown"
  end

  def test_a_single_trial_reports_failure_lines_name_no_trial
    single = report.failures_markdown.lines(chomp: true)

    assert_equal 6, single.size
    assert_equal "- `s_queue` on `gpt-5-mini`: expected tool not called — Expected inbox_status to be called; the agent called find_tickets.", single.first
    assert single.all? { |line| line.match?(/\A- `[^`]+` on `[^`]+`: /) }, single.join("\n")
    assert_not_includes report.failures_markdown, "trial"
    assert_not_includes gated_report.failures_markdown, "trial"
  end

  def test_gates_over_replayed_scenarios_count_every_replay_and_passed_follows_the_bars
    report = replayed_report
    gates = report.gates

    assert_equal 3, report.trials
    assert_equal [ [ "orders", 5, 6 ], [ "help", 2, 3 ], [ "experimental", 0, 3 ], [ nil, 9, 12 ] ],
                 gates.map { |gate| [ gate.group, gate.passed, gate.total ] },
                 "the All row counts the 12 gated replays, the ungated experimental ones left out"
    assert_equal [ "Order support · gpt-5-mini: 5/6 (83%) passed, below 100%",
                   "Product help · gpt-5-mini: 2/3 (67%) passed, below 80%",
                   "Experimental · gpt-5-mini: 0/3 (0%) passed, not gated",
                   "All · gpt-5-mini: 9/12 (75%) passed, below 80%" ], gates.map(&:to_s)
    assert_equal [ 6, 5 ], report.summary_by_group.dig("orders", "models", gpt.label).values_at("scenarios", "passed")
    assert_equal [ "| Order support | `gpt-5-mini` | 5 of 6 | 83% ❌ | 100% | 92% |",
                   "| Product help | `gpt-5-mini` | 2 of 3 | 67% ❌ | 80% | 83% |",
                   "| Experimental | `gpt-5-mini` | 0 of 3 | 0% — | not gated | 50% |",
                   "| All | `gpt-5-mini` | 9 of 12 | 75% ❌ | 80% | 80% |" ], report.gates_markdown.last(4)
    assert_equal [ [ 5, 6 ], [ 9, 12 ] ], report.to_h["gates"].values_at(0, 3).map { |gate| gate.values_at("passed", "total") }

    assert_not report.passed?
    assert report.passed?(LENIENT)
    groups = { "orders" => { "min_pass_rate" => 0.8 }, "help" => { "min_pass_rate" => 0.6 }, "experimental" => { "gated" => false } }
    assert report.passed?(PassThresholds.new(suite: { "min_pass_rate" => 0.75 }, groups: groups)), "5/6 clears 80%, 2/3 clears 60%, and 9/12 meets 75%"
    assert_not report.passed?(PassThresholds.new(suite: { "min_pass_rate" => 0.76 }, groups: groups)),
               "one more point on the suite's bar and the All row's 9/12 falls short"
  end

  def test_to_h_and_the_markdown_name_the_trials_only_when_a_scenario_was_replayed
    assert_not report.to_h.key?("trials")
    assert report.to_h["results"].none? { |entry| entry.key?("trial") }, "a single-trial report serializes as an earlier gem wrote it"
    assert_not_includes report.to_markdown, "replayed"

    hash = trial_report.to_h
    assert_equal 3, hash["trials"]
    assert_equal %w[models trials criteria recommendations verdict comparison metadata results], hash.keys
    assert_equal [ 1, 1, 2, 3 ], hash["results"].select { |entry| entry["scenario_key"] == "s_inbox" }.map { |entry| entry["trial"] }
    assert_includes trial_report.to_markdown,
                    "No judge; scored on rules and expectations alone.\n\nEach scenario was replayed 3 times; a model's pass rate counts every replay.\n\n| Model | Passed |"
  end

  def test_html_renders_a_trials_cell_per_replayed_model_and_names_the_trials_beside_the_scenario_count
    html = visible(flaky_report.to_html)

    assert_includes html, "<title>Evaluation — 2 scenarios × 2 models · 3 trials per scenario</title>"
    assert_includes html, %(<div class="micro">Scenario runs</div><div class="value">10</div><div class="sub">2 scenarios × 2 models · 3 trials per scenario</div>)
    assert_includes html, %(<span class="meta">2 scenarios in 1 group · 3 trials per scenario</span>)
    assert_includes html, %(<div class="cell"><div class="top"><span class="s">2/3 · 67% passed</span></div>) +
                          %(<div class="top trial"><span class="muted">1</span><span class="g tone-success">[+]</span><span class="s tone-success">100%</span></div>) +
                          %(<div class="top trial"><span class="muted">2</span><span class="g tone-success">[+]</span><span class="s tone-success">100%</span></div>) +
                          %(<div class="top trial"><span class="muted">3</span><span class="g tone-error">[!]</span><span class="s tone-error">50%</span><span class="f">expected tool not called</span></div>) +
                          %(<div class="cost-line">$0.0030</div></div>)
    assert_includes html, %(<span class="s tone-error">0/2 · 0% passed</span>)
    assert_includes html, %(<span class="s tone-success">2/2 · 100% passed</span>)
    assert_includes html, %(<span class="group-pass">3/6 · 50% passed</span><span class="group-pass">2/4 · 50% passed</span>), "a group counts every replay"
    assert_includes html, %(<span class="name">gpt-5-mini</span><span class="micro sm">trial 3</span><span class="badge error">failed · 50%</span>)
    assert_equal 4, html.scan(%(<span class="micro sm">trial 2</span>)).size, "every model replayed every scenario at least twice"
    assert_equal 2, html.scan(%(<span class="micro sm">trial 3</span>)).size, "only gpt-5-mini replayed them a third time"
    ids = html.scan(/ id="([^"]*)"/).flatten
    assert_equal ids.uniq, ids, "every id stays unique across the trials"

    single = report.to_html
    assert_not_includes single, "trials per scenario"
    assert_not_includes single, %(class="top trial")
    assert_not_includes single, ">trial "
  end

  def test_the_trials_cells_cost_line_sums_the_replays_and_marks_an_estimate_or_a_missing_price
    inbox = scenario("s_inbox", "Is the support inbox receiving email?", group: "desk", tools: [ "inbox_status" ])
    healthy = ->(trial, **attributes) { result(inbox, gpt, replay(answer: "All healthy.", tool_calls: [ { "name" => "inbox_status" } ], **attributes), trial: trial) }
    estimated = Report.new(models: [ gpt ], results: [
      healthy.call(1, cost: 0.001, metadata: { "cost_source" => "reported" }),
      healthy.call(2, input_tokens: 100, output_tokens: 10, cost: 0.002,
                      metadata: { "cost_source" => "estimated", "cost_rate" => RATE, "judge_usage" => { "calls" => 1, "cost" => 0.0005 } })
    ])
    partly_priced = Report.new(models: [ gpt ], results: [ healthy.call(1, cost: 0.001), healthy.call(2) ])

    assert_includes estimated.to_html,
                    %(<div class="cost-line" title="estimated: 100 in × $5.00/M + 10 out × $30.00/M · catalog rate">~$0.0030 · judge $0.000500</div>)
    assert_includes partly_priced.to_html, %(<div class="cost-line">~$0.0010</div>),
                    "a replay with no price makes the sum a lower bound, with no token working to show"
  end
end
