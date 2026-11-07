# frozen_string_literal: true

# Builds the RSpec matcher and TestHelper's gate assertion with only the
# evaluation module and the test helper loaded: neither rspec nor the agent
# framework.
require "active_agent/evals/rspec"
require "active_agent/evals/test_helper"

raise "the framework should not be loaded" if defined?(ActiveAgent::Base)
raise "active_agent/evals/rspec must not define RSpec" if defined?(::RSpec)

lookup = ActiveAgent::Evals::Scenario.from_hash(
  { "key" => "lookup_1", "prompt" => "Where is order ABC-123?", "expect" => { "contains" => [ "ABC-123" ] } }, group: "orders"
)
tone = ActiveAgent::Evals::Scenario.from_hash(
  { "key" => "tone_1", "prompt" => "Draft a reply in the customer's tone.", "expect" => { "contains" => [ "Dear" ] } }, group: "experimental"
)
thresholds = ActiveAgent::Evals::PassThresholds.new(groups: { "experimental" => { "gated" => false } })
model = ActiveAgent::Evals::ModelSpec.parse("test-model", default_provider: "openai")
report = ActiveAgent::Evals::Runner.new(
  scenarios: [ lookup, tone ], models: [ model ], pass_thresholds: thresholds,
  replay: ->(*) { ActiveAgent::Evals::Replay.new(answer: "Order ABC-123 shipped on Monday.") }
).call
raise "expected the report to carry the bars" unless report.pass_thresholds == thresholds

check = ActiveAgent::Evals::GateCheck.new(report)
raise "expected every gate met, got #{check.message.inspect}" unless check.met? && check.message == "every pass gate met"

strict = ActiveAgent::Evals::GateCheck.new(report, ActiveAgent::Evals::PassThresholds.default)
raise "expected the experimental gate missed by default, got #{strict.message.inspect}" unless strict.message.start_with?("2 of 3 pass gates not met")

matcher = Object.new.extend(ActiveAgent::Evals::RSpec).meet_its_pass_gates
raise "expected the matcher to match, got #{matcher.failure_message.inspect}" unless matcher.matches?(report)
raise "expected the matcher's description, got #{matcher.description.inspect}" unless matcher.description == "meet its pass gates"

host = Class.new do
  include ActiveAgent::Evals::TestHelper

  def assert(test, message = nil)
    raise message.to_s unless test
  end
end.new
raise "expected the assertion to return the check" unless host.assert_meets_pass_gates(report).met?

failure = begin
  host.assert_meets_pass_gates(report, ActiveAgent::Evals::PassThresholds.default)
  nil
rescue RuntimeError => error
  error.message
end
raise "expected the assertion to fail with the check's message, got #{failure.inspect}" unless failure == strict.message

puts "ok"
