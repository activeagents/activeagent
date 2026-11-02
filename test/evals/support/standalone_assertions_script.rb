# frozen_string_literal: true

# Builds the RSpec matcher and the Minitest assertion with only the
# evaluation module loaded: neither test framework, nor the agent framework.
require "active_agent/evals/rspec"
require "active_agent/evals/minitest"

raise "the framework should not be loaded" if defined?(ActiveAgent::Base)
raise "active_agent/evals/rspec must not define RSpec" if defined?(::RSpec)
raise "active_agent/evals/minitest must not load minitest" if defined?(::Minitest)

scenario = ActiveAgent::Evals::Scenario.from_hash({ "key" => "lookup_1", "prompt" => "Where is order ABC-123?" })
model = ActiveAgent::Evals::ModelSpec.parse("test-model", default_provider: "openai")
report = ActiveAgent::Evals::Runner.new(
  scenarios: [ scenario ], models: [ model ],
  replay: ->(*) { ActiveAgent::Evals::Replay.new(answer: "Order ABC-123 shipped on Monday.") }
).call

check = ActiveAgent::Evals::GateCheck.new(report)
raise "expected every gate met, got #{check.message.inspect}" unless check.met? && check.message == "every pass gate met"

matcher = Object.new.extend(ActiveAgent::Evals::RSpec).meet_its_pass_gates
raise "expected the matcher to match, got #{matcher.failure_message.inspect}" unless matcher.matches?(report)
raise "expected the matcher's description, got #{matcher.description.inspect}" unless matcher.description == "meet its pass gates"

host = Object.new.extend(ActiveAgent::Evals::Minitest::Assertions)
def host.assert(test, message = nil)
  raise message.to_s unless test
end
host.assert_meets_pass_gates(report)

puts "ok"
