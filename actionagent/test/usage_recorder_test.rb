# frozen_string_literal: true

require "test_helper"

# ActionAgent.record_usage hands a quantity only to a usage_recorder that
# takes one, so a recorder written for (owner, kind) keeps working.
class UsageRecorderTest < ActiveSupport::TestCase
  class Recorder
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(owner, kind, quantity = nil)
      @calls << [ owner, kind, quantity ]
    end
  end

  def teardown
    ActionAgent.usage_recorder = nil
  end

  test "a recorder that takes a third argument receives the quantity" do
    calls = []
    ActionAgent.usage_recorder = ->(owner, kind, quantity) { calls << [ owner, kind, quantity ] }

    ActionAgent.record_usage(:acme, :browser_minutes, 4)
    ActionAgent.record_usage(:acme, :execution)

    assert_equal [ [ :acme, :browser_minutes, 4 ], [ :acme, :execution, nil ] ], calls
  end

  test "a recorder that takes two is called without the quantity" do
    calls = []
    ActionAgent.usage_recorder = ->(owner, kind) { calls << [ owner, kind ] }

    ActionAgent.record_usage(:acme, :browser_minutes, 4)

    assert_equal [ [ :acme, :browser_minutes ] ], calls
  end

  test "an object with #call, a proc and a splat are read the same way" do
    recorder = Recorder.new
    ActionAgent.usage_recorder = recorder
    ActionAgent.record_usage(:acme, :browser_minutes, 2)
    ActionAgent.record_usage(:acme, :execution)
    assert_equal [ [ :acme, :browser_minutes, 2 ], [ :acme, :execution, nil ] ], recorder.calls

    calls = []
    ActionAgent.usage_recorder = proc { |owner, kind| calls << [ owner, kind ] }
    ActionAgent.record_usage(:acme, :browser_minutes, 2)
    ActionAgent.usage_recorder = ->(*args) { calls << args }
    ActionAgent.record_usage(:acme, :browser_minutes, 3)
    assert_equal [ [ :acme, :browser_minutes ], [ :acme, :browser_minutes, 3 ] ], calls
  end
end
