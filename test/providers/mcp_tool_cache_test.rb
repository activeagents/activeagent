# frozen_string_literal: true

require "test_helper"
require "active_agent/providers/mcp_tool_cache"

# The cache's own behaviour: what it stores, when it expires, what it hands
# back, and what it refuses to be configured with.
class MCPToolCacheTest < ActiveSupport::TestCase
  CACHE = ActiveAgent::Providers::MCPToolCache

  # The cache is process-global by design — that is what makes it useful across
  # generations — so a test has to put it back the way it found it.
  teardown { CACHE.reset! }

  def tool(name)
    { name:, description: "#{name} tool", parameters: { type: "object", properties: {} } }
  end

  test "computes on a miss and reuses the result" do
    calls = 0

    first  = CACHE.fetch("alpha") { calls += 1; [ tool("one") ] }
    second = CACHE.fetch("alpha") { calls += 1; [ tool("two") ] }

    assert_equal 1, calls, "the second lookup must not go back to the server"
    assert_equal %w[one], first.pluck(:name)
    assert_equal %w[one], second.pluck(:name)
  end

  test "keeps entries apart by key" do
    CACHE.fetch("alpha") { [ tool("one") ] }
    CACHE.fetch("beta")  { [ tool("two") ] }

    assert_equal %w[one], CACHE.fetch("alpha") { [ tool("never") ] }.pluck(:name)
    assert_equal %w[two], CACHE.fetch("beta") { [ tool("never") ] }.pluck(:name)
  end

  # Providers hand these hashes to the request, and a transform may write to
  # them (Anthropic injects `additionalProperties`). A shared object would let
  # one generation corrupt what the next one sends.
  test "hands back a copy, so a caller cannot corrupt the entry" do
    CACHE.fetch("alpha") { [ tool("one") ] }

    first = CACHE.fetch("alpha") { [ tool("never") ] }
    first.first[:parameters][:properties][:injected] = true
    first.first[:name] = "renamed"

    second = CACHE.fetch("alpha") { [ tool("never") ] }

    assert_equal "one", second.first[:name]
    assert_empty second.first[:parameters][:properties]
  end

  test "does not keep a reference to what the block returned" do
    built = [ tool("one") ]
    CACHE.fetch("alpha") { built }

    built.first[:name] = "mutated"

    assert_equal %w[one], CACHE.fetch("alpha") { [ tool("never") ] }.pluck(:name)
  end

  test "expires an entry once its ttl has passed" do
    CACHE.configure(ttl: 0.01)

    CACHE.fetch("alpha") { [ tool("one") ] }
    sleep 0.02
    calls = 0
    recheck = CACHE.fetch("alpha") { calls += 1; [ tool("two") ] }

    assert_equal 1, calls, "an expired entry must be recomputed"
    assert_equal %w[two], recheck.pluck(:name)
  end

  test "drops an expired entry rather than leaving it to expire twice" do
    CACHE.configure(ttl: 0.01)
    CACHE.fetch("alpha") { [ tool("one") ] }
    sleep 0.02

    CACHE.fetch("alpha") { [ tool("two") ] }

    assert_equal 1, CACHE.stats[:size], "the stale entry must be gone, not replaced in place"
  end

  test "evicts the oldest entry once it is over the limit" do
    CACHE.configure(max_entries: 2)

    CACHE.fetch("alpha") { [ tool("one") ] }
    CACHE.fetch("beta")  { [ tool("two") ] }
    CACHE.fetch("gamma") { [ tool("three") ] }

    assert_equal 2, CACHE.stats[:size]

    # `alpha` was written first, so it is the one that went.
    calls = 0
    CACHE.fetch("alpha") { calls += 1; [ tool("one") ] }

    assert_equal 1, calls
  end

  test "recomputes every time when disabled, and stores nothing" do
    CACHE.configure(enabled: false)
    calls = 0

    2.times { CACHE.fetch("alpha") { calls += 1; [ tool("one") ] } }

    assert_equal 2, calls
    assert_equal 0, CACHE.stats[:size]
  end

  test "invalidate drops one entry and leaves the rest" do
    CACHE.fetch("alpha") { [ tool("one") ] }
    CACHE.fetch("beta")  { [ tool("two") ] }

    CACHE.invalidate("alpha")

    calls = 0
    CACHE.fetch("alpha") { calls += 1; [ tool("one") ] }
    CACHE.fetch("beta")  { calls += 1; [ tool("two") ] }

    assert_equal 1, calls, "only the invalidated key should have been recomputed"
  end

  test "clear! empties it and resets the counters" do
    CACHE.fetch("alpha") { [ tool("one") ] }
    CACHE.fetch("alpha") { [ tool("never") ] }

    CACHE.clear!

    assert_equal({ size: 0, hits: 0, misses: 0 }, CACHE.stats)
  end

  test "counts hits and misses" do
    CACHE.fetch("alpha") { [ tool("one") ] }
    CACHE.fetch("alpha") { [ tool("never") ] }
    CACHE.fetch("alpha") { [ tool("never") ] }

    assert_equal({ size: 1, hits: 2, misses: 1 }, CACHE.stats)
  end

  test "reset! restores the defaults" do
    CACHE.configure(ttl: 1, max_entries: 1, enabled: false)
    CACHE.fetch("alpha") { [ tool("one") ] }

    CACHE.reset!

    assert_equal CACHE::DEFAULT_TTL, CACHE.ttl
    assert_equal CACHE::DEFAULT_MAX_ENTRIES, CACHE.max_entries
    assert_predicate CACHE, :enabled?
    assert_equal({ size: 0, hits: 0, misses: 0 }, CACHE.stats)
  end

  test "refuses a ttl that would never expire" do
    error = assert_raises(ArgumentError) { CACHE.configure(ttl: 0) }

    assert_includes error.message, "positive number"
  end

  test "refuses an entry limit of zero" do
    error = assert_raises(ArgumentError) { CACHE.configure(max_entries: 0) }

    assert_includes error.message, "positive Integer"
  end

  # The cache is shared by every thread in the process, so a concurrent burst
  # must not corrupt it or lose an entry.
  test "survives concurrent use" do
    tools   = [ tool("one") ]
    threads = 8

    threads.times.map do
      Thread.new do
        50.times do
          CACHE.fetch("alpha") { tools }
          CACHE.fetch("beta")  { tools }
        end
      end
    end.each(&:join)

    assert_equal 2, CACHE.stats[:size]
    assert_equal %w[one], CACHE.fetch("alpha") { [ tool("never") ] }.pluck(:name)
  end
end
