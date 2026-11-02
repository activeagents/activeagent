# frozen_string_literal: true

# Loaded by an explicit `require "active_agent/evals/rspec"` — never by
# `require "active_agent/evals"` — so a host on another test framework never
# sees it. It needs nothing from rspec: the matcher speaks RSpec's matcher
# protocol on its own and loads with rspec absent.
require_relative "../evals"

module ActiveAgent
  module Evals
    # `expect(report).to meet_its_pass_gates`: an RSpec matcher over
    # GateCheck, failing with its message. Include the module once in
    # `RSpec.configure`, or in one example group:
    #
    #   require "active_agent/evals/rspec"
    #
    #   RSpec.configure { |config| config.include ActiveAgent::Evals::RSpec }
    #
    #   RSpec.describe "the support desk suite" do
    #     # or, in this one group: include ActiveAgent::Evals::RSpec
    #     it "clears its pass gates" do
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

        def diffable?
          false
        end

        def supports_block_expectations?
          false
        end
      end
    end
  end
end
