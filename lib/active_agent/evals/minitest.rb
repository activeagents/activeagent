# frozen_string_literal: true

# Loaded by an explicit `require "active_agent/evals/minitest"` — never by
# `require "active_agent/evals"` — so a host on another test framework never
# sees it. It needs nothing from minitest itself: the test class that
# includes it supplies `assert`.
require_relative "../evals"

module ActiveAgent
  module Evals
    module Minitest
      # `assert_meets_pass_gates(report)`: a Minitest assertion over
      # GateCheck, failing with its message. Include it in a test class,
      # Minitest::Test or ActiveSupport::TestCase, which supply `assert`:
      #
      #   require "active_agent/evals/minitest"
      #
      #   class SupportDeskEvalTest < ActiveSupport::TestCase
      #     include ActiveAgent::Evals::Minitest::Assertions
      #
      #     test "the support desk suite clears its pass gates" do
      #       assert_meets_pass_gates(report)
      #     end
      #   end
      module Assertions
        # Passes when every gate of `report` is met under `thresholds` (or
        # without them under the report's own bars, else the defaults);
        # fails with GateCheck#message, or with `message` when one is given.
        def assert_meets_pass_gates(report, thresholds = nil, message = nil)
          check = GateCheck.new(report, thresholds)
          assert check.met?, message || check.message
        end
      end
    end
  end
end
