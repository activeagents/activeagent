# frozen_string_literal: true

require "json"
require "yaml"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/access"
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/hash/indifferent_access"
require "active_support/core_ext/enumerable"

require_relative "evals/version"
require_relative "evals/scenario"
require_relative "evals/scenario_parser"
require_relative "evals/suite"
require_relative "evals/model_spec"
require_relative "evals/replay"
require_relative "evals/scorer"
require_relative "evals/diagnosis"
require_relative "evals/judge"
require_relative "evals/result"
require_relative "evals/report"
require_relative "evals/runner"

# Scenario evaluations for agents that answer with tools.
#
# The gem owns everything about an evaluation except talking to the agent:
# parsing a pasted list of tasks (ScenarioParser) or a YAML suite (Suite),
# resolving candidate models (ModelSpec), scoring an answer against rule
# criteria and the scenario's expectations (Scorer), naming why a scenario
# fell short and what would fix it (Diagnosis, refined by an optional Judge),
# and rolling everything up per model (Report). Runner ties them together
# around one callable you supply: given a scenario and a model, run the
# agent and return a Replay.
#
#   scenarios = ActiveAgents::Evals::ScenarioParser.parse(pasted_text)
#                 .map { |attrs| ActiveAgents::Evals::Scenario.from_hash(attrs) }
#   models    = ActiveAgents::Evals::ModelSpec.parse_all(%w[gpt-5-mini qwen3:8b], default_provider: "openai")
#
#   report = ActiveAgents::Evals::Runner.new(
#     scenarios: scenarios,
#     models: models,
#     available_tools: { "find_records" => "Look up records by filters" },
#     replay: ->(scenario, spec) { my_agent.run(scenario.prompt, model: spec.model, provider: spec.provider) }
#   ).call
#
#   puts report.to_markdown
module ActiveAgents
  module Evals
    # The score at or above which a scenario passes, 0.0..1.0.
    PASS_THRESHOLD = 0.7
  end
end
