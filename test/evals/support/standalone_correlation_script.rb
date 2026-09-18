# frozen_string_literal: true

# Drives a correlated run end to end with only the evaluation module loaded.
require "active_agent/evals"

raise "the framework should not be loaded" if defined?(ActiveAgent::Base)

traces = []
tracer = lambda do |name, action:, attributes:, on_trace:, &block|
  trace_id = "trace-#{traces.size + 1}"
  traces << { name: name, action: action, attributes: attributes }
  on_trace&.call(Struct.new(:trace_id).new(trace_id))
  block.call
end

correlation = ActiveAgent::Evals::Correlation.new(agent_name: "SupportAgent", tracer: tracer)
scenario = ActiveAgent::Evals::Scenario.from_hash({ "key" => "lookup_1", "prompt" => "Where is order ABC-123?" })
model = ActiveAgent::Evals::ModelSpec.parse("test-model", default_provider: "openai")

report = correlation.with_run("suite" => "support") do |metadata|
  ActiveAgent::Evals::Runner.new(
    scenarios: [ scenario ], models: [ model ], metadata: metadata, around_evaluation: correlation,
    replay: ->(*) { correlation.replay { ActiveAgent::Evals::Replay.new(answer: "Order ABC-123 shipped on Monday.") } }
  ).call
end

metadata = report.results.first.replay.metadata
raise "expected a result id, got #{metadata.inspect}" unless metadata["result_id"]
raise "expected the replay trace id, got #{metadata.inspect}" unless metadata["trace_id"] == "trace-1"
raise "expected the eval attributes, got #{traces.inspect}" unless traces.first[:attributes]["eval.suite"] == "support"

puts "ok"
