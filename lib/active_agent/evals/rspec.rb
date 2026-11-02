# frozen_string_literal: true

# Loaded by an explicit `require "active_agent/evals/rspec"` — never by
# `require "active_agent/evals"` — so a host on another test framework never
# sees it. It needs nothing from rspec: the matcher speaks RSpec's matcher
# protocol on its own and loads with rspec absent.
require_relative "../evals"

module ActiveAgent
  module Evals
    # `expect(report).to meet_its_pass_gates`: an RSpec matcher over
    # GateCheck, failing with its message, as TestHelper's
    # `assert_meets_pass_gates` does. Include it beside TestHelper where the
    # evals are set up, tagged and run only when EVALS is on:
    #
    #   # spec/rails_helper.rb
    #   require "active_agent/evals/test_helper"
    #   require "active_agent/evals/rspec"
    #
    #   RSpec.configure do |config|
    #     config.expect_with :rspec, :minitest
    #     config.define_derived_metadata(file_path: %r{/spec/evals/}) { |metadata| metadata[:eval] = true }
    #     config.include ActiveAgent::Evals::TestHelper, eval: true
    #     config.include ActiveAgent::Evals::RSpec, eval: true
    #     config.filter_run_excluding eval: true unless ActiveAgent::Evals::TestHelper.enabled?
    #   end
    #
    #   # spec/evals/support_desk_spec.rb
    #   RSpec.describe "the support desk suite" do
    #     it "clears its pass gates" do
    #       report = run_eval_suite("config/evals/support_desk.yml") { |scenario, _spec| SupportAgent.with(question: scenario.prompt).help }
    #
    #       expect(report).to meet_its_pass_gates
    #     end
    #   end
    module RSpec
      # The matcher: every gate of the report met under `thresholds`, or
      # without them under the report's own bars, else the defaults.
      def meet_its_pass_gates(thresholds = nil)
        MeetItsPassGates.new(thresholds)
      end

      # The matcher object, speaking RSpec's matcher protocol (`matches?`,
      # the failure messages and `description`) without rspec loaded.
      class MeetItsPassGates
        def initialize(thresholds = nil)
          @thresholds = thresholds
        end

        # Checks `report` and keeps the check for the failure messages.
        def matches?(report)
          @check = GateCheck.new(report, @thresholds)
          @check.met?
        end

        # GateCheck#message: the unmet gates and the failures to read.
        def failure_message
          @check.message
        end

        # For `expect(report).not_to meet_its_pass_gates`: every gate, each
        # met, as Gate#to_s.
        def failure_message_when_negated
          [ "expected the report not to meet its pass gates, but every gate was met:", *@check.gates.map(&:to_s) ].join("\n")
        end

        # The generated example description: "meet its pass gates", or
        # "meet the given pass gates" when thresholds were passed.
        def description
          @thresholds ? "meet the given pass gates" : "meet its pass gates"
        end

        # RSpec shows no diff: the failure message already lists the unmet
        # gates.
        def diffable?
          false
        end

        # The matcher takes a report, not a block, so RSpec refuses
        # `expect { ... }.to meet_its_pass_gates`.
        def supports_block_expectations?
          false
        end
      end
    end
  end
end
