# frozen_string_literal: true

require "minitest/autorun"
require "ostruct"
require_relative "../lib/active_agent/integrations/memcode"

class MemcodeIntegrationTest < Minitest::Test
  Memcode = ActiveAgent::Integrations::Memcode

  def setup
    @requests = []
    @data = { "id" => "job-1", "status" => "queued" }
    @http_status = "200"
    @transport = lambda do |uri, request|
      @requests << [ uri, request ]
      OpenStruct.new(code: @http_status, body: JSON.generate(status: "ok", data: @data))
    end
    @client = Memcode::Client.new(api_key: "synthetic-key", transport: @transport)
  end

  def memory(user = "alice", space = "space-a")
    Memcode::Memory.new(client: @client, user_id: user, actor_id: "actor-#{user}", space_id: space)
  end

  def test_two_invocations_recall_only_the_authorized_users_records
    receipt = memory.remember(content: "Use concise replies")
    assert_equal "queued", receipt.fetch("status")
    payload = JSON.parse(@requests.last[1].body)
    assert_equal "alice", payload.dig("metadata", "user_id")
    assert_equal "space-a", payload.fetch("space_id")
    @data = { "results" => [
      record("alice", "space-a", "Use concise replies"),
      record("bob", "space-a", "private-bob"),
      record("alice", "space-b", "private-space"),
      { "content" => "unattributed" },
      { "space" => "invalid", "metadata" => false, "content" => "malformed" }
    ] }
    assert_equal [ { "content" => "Use concise replies", "score" => 0.9 } ], memory.recall(query: "style")
    assert_empty memory("bob", "space-b").recall(query: "style")
    assert_equal "context_only", JSON.parse(@requests.last[1].body).fetch("scope")
  end

  def test_idempotency_is_stable_and_separated_by_user_and_content
    memory.remember(content: "approved")
    key = @requests.last[1]["Idempotency-Key"]
    memory.remember(content: "approved")
    assert_equal key, @requests.last[1]["Idempotency-Key"]
    memory("bob").remember(content: "approved")
    refute_equal key, @requests.last[1]["Idempotency-Key"]
  end

  def test_invalid_scope_query_and_limits_do_not_make_requests
    assert_raises(ArgumentError) { memory("", "space-a") }
    assert_raises(ArgumentError) { memory.recall(query: " ") }
    assert_raises(ArgumentError) { memory.recall(query: "style", limit: 0) }
    assert_empty @requests
  end

  def test_status_uses_encoded_job_id_and_never_retries_a_failed_write
    @client.ingest_status("job/one")
    assert_equal "/v2/memory/ingest/job%2Fone", @requests.last[0].path
    @http_status = "503"
    error = assert_raises(Memcode::Error) { memory.remember(content: "approved") }
    assert_equal "MemCode request failed (HTTP 503)", error.message
    assert_equal 2, @requests.size
  end

  def test_network_errors_do_not_leak_credentials_or_provider_payloads
    client = Memcode::Client.new(api_key: "synthetic-key", transport: lambda { |*|
      raise IOError, "synthetic-key and private prompt"
    })
    error = assert_raises(Memcode::Error) { client.search(space_id: "a", actor_id: "alice", query: "x", limit: 1) }
    assert_equal "MemCode is unavailable", error.message
  end

  def test_bad_envelope_and_insecure_origin_are_rejected
    assert_raises(ArgumentError) { Memcode::Client.new(api_key: "x", api_url: "http://example.test") }
    client = Memcode::Client.new(api_key: "x", transport: lambda { |*|
      OpenStruct.new(code: "200", body: '{"status":"error","data":{"secret":"private"}}')
    })
    assert_raises(Memcode::Error) { client.ingest_status("one") }
  end

  private

  def record(user, space, content)
    { "content" => content, "score" => 0.9, "space" => { "id" => space }, "metadata" => { "user_id" => user } }
  end
end
