# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsReportTest < ActiveSupport::TestCase
  include EvalsTestSupport

  Result = ActiveAgent::Evals::Result
  Diagnosis = ActiveAgent::Evals::Diagnosis
  Report = ActiveAgent::Evals::Report

  AVAILABLE = %w[find_records healthcheck sync_status].freeze
  LINKS = { "mcp" => "/activeagents/mcp/%{key}", "tools" => "/activeagents/tools", "instructions" => "/activeagents/agents/1/edit" }.freeze
  SERVERS = {
    "sync_status" => { "key" => "sparkle_diagnostic", "name" => "Sparkle Diagnostic", "status" => "enabled" },
    "search_slots" => { "key" => "sparkle_match", "name" => "Sparkle Match", "status" => "available" },
    "book_slot" => { "key" => "sparkle_match", "name" => "Sparkle Match", "status" => "available" }
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
    health = scenario("s_health", "Run a healthcheck on this deployment", group: "diag", tools: [ "healthcheck" ])
    jobs = scenario("s_jobs", "Are there any stuck background jobs?", group: "diag", tools: [ "healthcheck" ])
    sync = scenario("s_sync", "Is content sync healthy?", group: "diag", tools: [ "sync_status" ])
    slots = scenario("s_slots", "Find the next available <b>slots</b> for a dermatologist", group: "match", tools: [ "search_slots" ])
    blame = scenario("s_blame", "Who changed the biography?", group: "blame")
    long_error = "no Physician with id=0 — the record was deleted before the tool ran, try again with a valid id"

    [
      result(health, gpt, replay(answer: "All healthy.", tool_calls: [ { "name" => "healthcheck" } ], duration_ms: 2_500, input_tokens: 80, output_tokens: 9, cost: 0.0012)),
      result(health, llama, replay(answer: "Healthy.", tool_calls: [ { "name" => "healthcheck" }, { "name" => "check_async" } ], duration_ms: 900)),
      result(jobs, gpt, replay(answer: "No stuck jobs.", tool_calls: [ { "name" => "find_records" } ]), score: 0.5),
      result(jobs, llama, replay(answer: "None stuck.", tool_calls: [ { "name" => "healthcheck" } ])),
      result(sync, gpt, replay(answer: "Sync looks fine.", tool_calls: [ { "name" => "healthcheck" } ]), score: 0.5),
      result(sync, llama, replay(answer: "Sync is broken.", tool_calls: [ { "name" => "sync_status", "error" => true, "detail" => long_error }, { "name" => "sync_status", "error" => true, "detail" => long_error } ]), score: 0.5),
      result(slots, gpt, replay(answer: "<img src=x onerror=alert(1)> no slots", tool_calls: [ { "name" => "find_records" } ]), score: 0.5),
      result(slots, llama, replay(answer: "I don't have access to scheduling data."), score: 0.5,
             judge: { "recommendation" => "Give the agent a slot search tool.",
                      "suggested_tool" => { "name" => "book_slot", "description" => "Books a slot" },
                      "instruction_change" => "Use search_slots for appointment questions." }),
      result(blame, gpt, replay(answer: "Someone did."), score: 0.4,
             judge: { "recommendation" => "Add an audit tool.", "suggested_tool" => { "name" => "record_history", "description" => "Who changed what" } }),
      result(blame, llama, replay(answer: "Alice changed it on Monday."))
    ]
  end

  def report(**options)
    Report.new(results: results, models: models, metadata: { "evaluation" => "Sparkle suite", "run" => 3 }, **options)
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
    assert_equal %w[s_jobs s_sync s_slots], missing["scenario_keys"]
    assert_equal [ "gpt-5-mini" ], missing["models"]
    assert_equal "missing tools", missing["tools_label"]
    assert_equal %w[search_slots], missing["tools"].map { |tool| tool["name"] }
    assert_match(/\As_jobs is the exception: Expected healthcheck to be called; the agent called find_records\./, missing["note"])
    assert_match(/expects search_slots, which the agent does not have/, missing["recommendation"],
                 "the card speaks for the scenarios whose tool was missing, not for the exception it notes")
    assert_no_match(/answered with find_records/, missing["recommendation"])
    assert_nil missing["quote"]

    failing = by_fault["tool_error"]
    assert_equal "failing tools", failing["tools_label"]
    assert_equal 1, failing["tools"].size, "failing tools are deduplicated by name"
    assert_equal "sync_status", failing["tools"].first["name"]
    assert_equal 60, failing["tools"].first["note"].length
    assert_equal({ "label" => "Open failing tools", "hint" => "Tools ->", "path" => nil }, failing["action"])

    capability = by_fault["missing_capability"]
    assert_equal "suggested tools", capability["tools_label"]
    assert_equal %w[book_slot search_slots], capability["tools"].map { |tool| tool["name"] }
    assert_equal "Give the agent a slot search tool.", capability["recommendation"]
    assert_equal "Open suggested tools", capability["action"]["label"]

    quality = by_fault["low_quality"]
    assert_equal %w[record_history], quality["tools"].map { |tool| tool["name"] }
    assert_nil quality["server"]
    assert_nil quality["note"]

    instruction = by_fault["instruction change"]
    assert_equal "instruction", instruction["kind"]
    assert_equal "Use search_slots for appointment questions.", instruction["quote"]
    assert_equal [ "s_slots" ], instruction["scenario_keys"]
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
    items = report(tool_resolver: resolver, agent_name: "Clara", links: LINKS).fix_items
    by_fault = items.to_h { |item| [ item["fault"], item ] }

    missing = by_fault["expected_tool_not_called"]
    assert_equal({ "key" => "sparkle_match", "name" => "Sparkle Match", "status" => "available" }, missing["server"])
    assert_equal "Sparkle Match", missing["tools"].first["note"], "a missing tool's note is its server"
    assert_equal({ "label" => "Enable Sparkle Match for Clara", "hint" => "MCP Services ->", "path" => "/activeagents/mcp/sparkle_match" }, missing["action"])

    failing = by_fault["tool_error"]
    assert_equal "sparkle_diagnostic", failing["tools"].first.dig("server", "key")
    assert_equal "/activeagents/tools", failing["action"]["path"]
    assert_nil failing["server"], "only missing tools resolve to a shared server"

    assert_nil by_fault["low_quality"]["tools"].first["server"]
    assert_equal "/activeagents/agents/1/edit", by_fault["instruction change"]["action"]["path"]
  end

  def test_missing_tools_on_an_enabled_server_or_across_servers_fall_back_to_the_tools_page
    enabled = ->(_name) { { "key" => "sparkle_match", "name" => "Sparkle Match", "status" => "enabled" } }
    item = report(tool_resolver: enabled, links: LINKS).fix_items.first

    assert_equal "enabled", item.dig("server", "status")
    assert_equal({ "label" => "Open tools", "hint" => "Tools ->", "path" => "/activeagents/tools" }, item["action"])

    split = ->(name) { { "key" => name, "status" => nil } }
    item = Report.new(results: results, models: models, tool_resolver: split).fix_items.first

    assert_equal "unknown", item["tools"].first.dig("server", "status")
    assert_equal "search_slots", item["tools"].first.dig("server", "name"), "a server without a name reads as its key"
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
    html = report(tool_resolver: resolver, agent_name: "Clara", links: LINKS).to_html

    assert_includes html, "What to fix"
    assert_includes html, "5 items · 6 faults across 4 scenarios"
    assert_includes html, %(<span class="glyph tone-error">[!]</span>)
    assert_includes html, %(<span class="glyph tone-info">[i]</span>)
    assert_includes html, %(<span class="badge error">expected tool not called ×3</span>)
    assert_includes html, %(<span class="badge info">instruction change</span>)
    assert_includes html, "3 scenarios · gpt-5-mini"
    assert_includes html, "s_slots · judge suggestion"
    assert_includes html, "missing tools"
    assert_includes html, %(<b>search_slots</b><span class="note">Sparkle Match</span>)
    assert_includes html, %(<span>served by</span><b>Sparkle Match</b><span class="badge warning xs">available · not enabled for Clara</span>)
    assert_includes html, "s_jobs is the exception"
    assert_includes html, %(<a class="btn" target="_top" href="/activeagents/mcp/sparkle_match">Enable Sparkle Match for Clara</a><span class="hint">MCP Services -&gt;</span>),
                    "the action leaves the dashboard's report iframe rather than nesting the dashboard in it"
    assert_includes html, "“Use search_slots for appointment questions.”"
    assert_not_includes html, "expected_tool_not_called"
  end

  def test_html_without_links_renders_the_route_hint_only
    html = report(tool_resolver: resolver).to_html

    assert_not_includes html, %(class="btn")
    assert_includes html, %(<div class="action"><span class="hint">MCP Services -&gt;</span></div>)
  end

  def test_html_matrix_colors_calls_against_expectations_and_links_to_the_details
    html = report.to_html

    assert_includes html, %(<span class="group-name">diag</span><span class="count">3 scenarios</span>)
    assert_includes html, %(<span class="group-pass">1/3 passed</span><span class="group-pass">2/3 passed</span>)
    assert_includes html, %(<span class="group-pass text-error">0/1 passed</span><span class="group-pass text-success">1/1 passed</span>)
    assert_includes html, %(<span class="expect">sync_status</span>)
    assert_includes html, %(<span class="g tone-success">[+]</span><span class="s tone-success">1.00</span>)
    assert_includes html, %(<span class="g tone-error">[!]</span><span class="s tone-error">0.50</span><span class="f">tool error</span>)
    assert_includes html, %(<span class="call-hit">healthcheck</span><span>check_async</span>)
    assert_includes html, %(<span class="call-err">sync_status ✗ ×2</span>)
    assert_includes html, "no tools called"
    assert_includes html, %(<a href="#scenario-s_blame">s_blame</a>)
    assert_includes html, %(<div id="scenario-s_blame">)
    assert_includes html, "<details>"
    assert_includes html, %(<span class="badge success">passed · 1.00</span>)
    assert_includes html, %(<span class="badge error">failed · 0.50</span>)
    assert_includes html, "2.5s · 89 tokens · $0.0012"
    assert_includes html, "<b>[!] tool error</b> — Tool sync_status returned an error while answering."
    assert_includes html, "expects <b>search_slots</b>"
    assert_includes html, "<footer>"
    assert_includes html, "judge rules"
    assert_includes html, "criteria response present"
    assert_includes html, "evaluation Sparkle suite"
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
    prompt = "Find the next available dermatology slot, #{([ 'check it is not double booked' ] * 8).join(', ')}."
    html = Report.new(models: models.first(1), results: [
      result(scenario("s_long", prompt), gpt, replay(answer: "Booked."))
    ]).to_html

    assert_operator prompt.length, :>, 200
    assert_includes html, %(<div class="prompt">#{prompt}</div>), "the matrix cell wraps; it does not truncate"
    assert_not_includes html, "…"
  end

  def test_a_clean_run_keeps_the_what_to_fix_section
    html = Report.new(models: models.first(1), results: [
      result(scenario("s_1", "Who changed the biography?"), gpt, replay(answer: "Alice did, on Monday."))
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
