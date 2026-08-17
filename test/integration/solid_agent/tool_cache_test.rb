# frozen_string_literal: true

require_relative "integration_case"

# ToolCache is the one piece of solid_agent this repository calls directly:
# ActionAgent::AgentToolbox routes tool results through it when it is
# present, and falls back to a hand-rolled Rails.cache key when it isn't.
# These assertions pin the behaviour that fallback has to match.
class SolidAgentToolCacheTest < SolidAgentIntegrationTest
  requires_solid_agent "SolidAgent::ToolCache"

  setup do
    @previous_store = SolidAgent::ToolCache.store
    SolidAgent::ToolCache.store = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    SolidAgent::ToolCache.store = @previous_store
    SolidAgent::ToolCache.enabled = true
  end

  test "an identical call replays instead of running the side effect again" do
    calls = 0
    fetch = -> { SolidAgent::ToolCache.fetch(tool: "fetch_url", args: { url: "https://example.com" }) { calls += 1; { body: "hi" } } }

    assert_nil fetch.call[:cached]
    assert_equal({ body: "hi", cached: true }, fetch.call)
    assert_equal 1, calls, "the block should have run once"
  end

  test "keys ignore argument order and key type" do
    ordered = SolidAgent::ToolCache.cache_key("search", { query: "ruby", limit: 10 })
    shuffled = SolidAgent::ToolCache.cache_key("search", { "limit" => 10, "query" => "ruby" })

    assert_equal ordered, shuffled
    assert_match(/\Asolid_agent:tool_cache:search:/, ordered)
  end

  test "error results are never cached" do
    calls = 0
    2.times do
      SolidAgent::ToolCache.fetch(tool: "fetch_url", args: { url: "https://down.example" }) do
        calls += 1
        { error: "HTTP 500" }
      end
    end

    assert_equal 2, calls, "a transient failure must not stick for the TTL"
  end

  test "disabling it bypasses the store entirely" do
    SolidAgent::ToolCache.enabled = false
    calls = 0

    2.times { SolidAgent::ToolCache.fetch(tool: "t", args: {}) { calls += 1; { ok: true } } }

    assert_equal 2, calls
  end

  test "the dashboard routes tool results through this cache" do
    # AgentToolbox#cached_fetch prefers ToolCache when it is defined and
    # hand-rolls an equivalent Rails.cache key when it isn't. The two paths
    # have to agree on the key, or upgrading solid_agent silently invalidates
    # every cached tool result.
    args = { url: "https://example.com" }
    calls = 0

    result = ActionAgent::AgentToolbox.send(:cached_fetch, :fetch_url, args) do
      calls += 1
      { body: "hi" }
    end

    assert_equal({ body: "hi" }, result)
    assert_equal 1, calls
    assert_equal(
      { body: "hi" },
      SolidAgent::ToolCache.store.read(SolidAgent::ToolCache.cache_key("fetch_url", args)),
      "the dashboard's cached_fetch should write through SolidAgent::ToolCache's key scheme"
    )

    assert_equal SolidAgent::ToolCache.cache_key("fetch_url", args),
      ActionAgent::AgentToolbox.send(:fallback_cache_key, :fetch_url, args),
      "AgentToolbox's no-ToolCache fallback key has drifted from ToolCache's"

    nested = { filters: { b: 2, a: [ 1, { z: 0 } ] }, url: "https://example.com" }

    assert_equal SolidAgent::ToolCache.cache_key("fetch_url", nested),
      ActionAgent::AgentToolbox.send(:fallback_cache_key, :fetch_url, nested),
      "nested arguments must normalize the same way on both sides"
  end
end
