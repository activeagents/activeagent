# frozen_string_literal: true

# Reads a catalog and its pass bars with only the evaluation module loaded.
require "active_agent/evals"

raise "the framework should not be loaded" if defined?(ActiveAgent::Base)

catalog = ActiveAgent::Evals::Catalog.parse(<<~YAML)
  catalog: support_desk
  products:
    - key: triage
      pass: { min_pass_rate: 0.8 }
      sets:
        - key: smoke
          pass: { gated: false }
          scenarios:
            - key: smoke_1
              prompt: Where is order ABC-123?
YAML

thresholds = catalog.pass_thresholds(:triage)
raise "expected the product's bars, got #{thresholds.to_h.inspect}" unless thresholds.min_pass_rate == 0.8 && !thresholds.gated?(:smoke)
raise "expected one scenario, got #{catalog.scenario_count}" unless catalog.scenario_count == 1
raise "expected the digest to survive a round trip" unless ActiveAgent::Evals::Catalog.parse(catalog.to_yaml).digest == catalog.digest

puts "ok"
