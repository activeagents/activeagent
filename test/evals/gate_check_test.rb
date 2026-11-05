# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsGateCheckTest < ActiveSupport::TestCase
  include EvalsTestSupport

  GateCheck = ActiveAgent::Evals::GateCheck

  def test_met_and_unmet_read_the_reports_gates_under_its_own_bars
    report = gated_report
    check = GateCheck.new(report)

    assert_not check.met?
    assert_equal report.gates, check.gates
    assert_equal [ %w[orders gpt-5-mini], [ nil, "gpt-5-mini" ] ], check.unmet.map { |gate| [ gate.group, gate.label ] }
    assert GateCheck.new(passing_report).met?
    assert_empty GateCheck.new(passing_report).unmet
    assert_not GateCheck.new(Report.new(results: gated_results, models: models)).met?, "without bars, every scenario has to pass"
  end

  def test_given_bars_replace_the_reports_own
    check = GateCheck.new(gated_report, LENIENT)

    assert check.met?
    assert_empty check.unmet
    assert_equal 0.5, check.gates.first.min_pass_rate
    assert_equal "every pass gate met", check.message
    assert_equal gated_report.gates(PassThresholds.default), GateCheck.new(gated_report, PassThresholds.default).gates
  end

  def test_a_report_with_no_results_is_not_met_and_says_it_evaluated_nothing
    check = GateCheck.new(Report.new(results: [], models: models, pass_thresholds: THRESHOLDS))

    assert_not check.met?
    assert_empty check.gates
    assert_equal "no result reached a pass gate; the run evaluated nothing", check.message
  end

  def test_the_message_counts_the_unmet_gates_then_lists_them_and_each_groups_failures
    report = gated_report
    check = GateCheck.new(report)
    lines = check.message.lines(chomp: true)

    assert_equal "2 of 7 pass gates not met", lines[0]
    assert_equal "- Order support · gpt-5-mini: 1/2 (50%) passed, below 100%", lines[1]
    assert_equal "- All · gpt-5-mini: 3/4 (75%) passed, below 80%", lines[2]
    assert_equal [ "", "Order support failures:", report.failures_markdown(group: "orders") ], lines[3..5]
    assert_match(/\A- `order_status` on `gpt-5-mini`: low quality — /, lines[5])
    assert_equal 6, lines.size, "the experimental failures count toward no gate, so no section lists them"
    assert_not_includes check.message, "Failures:"
    assert_not check.message.end_with?("\n")
    assert_equal check.message, check.to_s
  end

  def test_each_group_with_an_unmet_gate_gets_one_section_in_gates_order
    short = %w[order_status help_cancel]
    results = gated_results.map { |built| short.include?(built.scenario.key) ? result(built.scenario, built.spec, built.replay, score: 0.5) : built }
    report = Report.new(results: results, models: models, pass_thresholds: THRESHOLDS)
    check = GateCheck.new(report)
    lines = check.message.lines(chomp: true)

    assert_equal [ %w[orders gpt-5-mini], [ "orders", llama.label ], %w[help gpt-5-mini], [ nil, "gpt-5-mini" ], [ nil, llama.label ] ],
                 check.unmet.map { |gate| [ gate.group, gate.label ] }
    assert_equal "5 of 7 pass gates not met", lines[0]
    assert_equal [ "", "Order support failures:", *report.failures_markdown(group: "orders").lines(chomp: true) ], lines[6..9]
    assert_match(/\A- `order_status` on `gpt-5-mini`: low quality — /, lines[8])
    assert_match(%r{\A- `order_status` on `openrouter/meta-llama/llama-3\.1-8b`: low quality — }, lines[9])
    assert_equal [ "", "Product help failures:", report.failures_markdown(group: "help") ], lines[10..12]
    assert_match(/\A- `help_cancel` on `gpt-5-mini`: low quality — /, lines[12])
    assert_equal 13, lines.size, "the ungated experimental failures are not listed"
    assert_equal 1, check.message.scan("Order support failures:").size, "one section per group, however many of its models are short"
  end

  def test_other_failures_are_listed_only_when_a_failure_sits_outside_every_unmet_group
    report = Report.new(results: gated_results.reject { |result| result.scenario.group == "experimental" }, models: models, pass_thresholds: THRESHOLDS)
    check = GateCheck.new(report)

    assert_equal [ %w[orders gpt-5-mini], [ nil, "gpt-5-mini" ] ], check.unmet.map { |gate| [ gate.group, gate.label ] }
    assert_equal "2 of 5 pass gates not met\n- Order support · gpt-5-mini: 1/2 (50%) passed, below 100%\n" \
                 "- All · gpt-5-mini: 3/4 (75%) passed, below 80%\n\nOrder support failures:\n#{report.failures_markdown(group: 'orders')}",
                 check.message

    ping = scenario("ping", "Are you there?", group: nil, tools: [ "inbox_status" ])
    results = gated_results[0...-1] << result(ping, gpt, replay(answer: "No.", tool_calls: [ { "name" => "inbox_status" } ]), score: 0.5)
    report = Report.new(results: results, models: models, pass_thresholds: THRESHOLDS)
    lines = GateCheck.new(report).message.lines(chomp: true)

    assert_equal "- All · gpt-5-mini: 2/4 (50%) passed, below 80%", lines[2]
    assert_equal [ "", "Other failures:" ], lines[6..7]
    assert_equal [ report.failure_markdown(report.failures.last) ], lines[8..], "the ungrouped failure the All row counts is listed, the ungated ones are not"
    assert_match(/\A- `ping` on `gpt-5-mini`: low quality — /, lines.last)
  end

  def test_failures_outside_the_unmet_groups_are_not_listed_while_every_all_row_holds
    bars = PassThresholds.new(suite: { "min_pass_rate" => 0.5 }, groups: { "orders" => { "min_pass_rate" => 1.0 }, "experimental" => { "gated" => false } })
    report = Report.new(results: gated_results, models: models, pass_thresholds: bars)
    check = GateCheck.new(report)

    assert_equal [ %w[orders gpt-5-mini] ], check.unmet.map { |gate| [ gate.group, gate.label ] }, "every All row clears the suite's bar"
    assert_equal "1 of 7 pass gates not met\n- Order support · gpt-5-mini: 1/2 (50%) passed, below 100%\n\nOrder support failures:\n#{report.failures_markdown(group: 'orders')}",
                 check.message
    assert_includes report.failures.map { |failed| failed.scenario.key }, "exp_1",
                    "the experimental failures exist, but no All row is short, so they are not listed"
  end

  def test_the_message_counts_every_replay_and_names_the_trial_of_each_failure
    report = replayed_report
    low_quality = "low quality — Scored 50% against a pass threshold of 70%, weakest on response_present (100%)."

    assert_equal <<~MESSAGE.chomp, GateCheck.new(report).message
      3 of 4 pass gates not met
      - Order support · gpt-5-mini: 5/6 (83%) passed, below 100%
      - Product help · gpt-5-mini: 2/3 (67%) passed, below 80%
      - All · gpt-5-mini: 9/12 (75%) passed, below 80%

      Order support failures:
      - `order_status` on `gpt-5-mini` · trial 2: #{low_quality}

      Product help failures:
      - `help_cancel` on `gpt-5-mini` · trial 3: #{low_quality}

      Other failures:
      - `ping` on `gpt-5-mini` · trial 1: #{low_quality}
    MESSAGE
    assert GateCheck.new(report, LENIENT).met?

    once = Report.new(results: report.results.select { |result| result.trial == 2 }, models: [ gpt ], pass_thresholds: THRESHOLDS)
    assert_includes GateCheck.new(once).message, "- `order_status` on `gpt-5-mini`: #{low_quality}", "one result per scenario × model names no trial, whatever its trial number"
  end

  def test_an_unmet_all_row_alone_lists_the_whole_reports_failures
    bars = PassThresholds.new(suite: { "min_pass_rate" => 0.9 }, groups: { "orders" => { "min_pass_rate" => 0.5 } })
    report = Report.new(results: gated_results.select { |result| result.label == gpt.label && result.scenario.group != "experimental" },
                        models: [ gpt ], pass_thresholds: bars)
    check = GateCheck.new(report)

    assert_equal [ [ nil, "gpt-5-mini" ] ], check.unmet.map { |gate| [ gate.group, gate.label ] }, "every group clears its own bar"
    assert_equal "1 of 3 pass gates not met\n- All · gpt-5-mini: 3/4 (75%) passed, below 90%\n\nFailures:\n#{report.failures_markdown}", check.message
    assert_equal [ "order_status" ], report.failures.map { |failed| failed.scenario.key }

    ungated = PassThresholds.new(suite: { "min_pass_rate" => 0.9 }, groups: { "orders" => { "min_pass_rate" => 0.5 }, "experimental" => { "gated" => false } })
    with_experimental = Report.new(results: gated_results.select { |result| result.label == gpt.label }, models: [ gpt ], pass_thresholds: ungated)

    assert_equal [ [ nil, "gpt-5-mini" ] ], GateCheck.new(with_experimental).unmet.map { |gate| [ gate.group, gate.label ] }
    assert_equal "1 of 4 pass gates not met\n- All · gpt-5-mini: 3/4 (75%) passed, below 90%\n\nFailures:\n#{with_experimental.failures_markdown(group: 'orders')}",
                 GateCheck.new(with_experimental).message, "the ungated group's failure is not among the failures the All row counts"
  end
end
