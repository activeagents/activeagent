# frozen_string_literal: true

# The publisher also works with saved report hashes, without loading Rails or
# the agent framework. Exercise that use directly.
require "minitest/autorun"
require "webmock/minitest"
require_relative "../../lib/active_agent/evals/publisher"

class EvalsPublisherTest < Minitest::Test
  ENDPOINT = "https://collector.example.test/v1/evaluations"
  Publisher = ActiveAgent::Evals::Publisher

  def arguments
    { report: { "results" => [ { "scenario_key" => "order_1", "answer" => "Shipped" } ] },
      run_id: "run-123", source: "support-app", agent_name: "SupportBot", suite: "orders" }
  end

  def receipt(duplicate: false)
    { run_id: "run-123", status: "complete", id: 5, evaluation_id: 3, duplicate: duplicate }
  end

  def publisher
    Publisher.new(endpoint: ENDPOINT, api_key: "private-test-key")
  end

  def test_sends_a_completed_report_and_returns_an_idempotent_receipt
    bodies = []
    request = stub_request(:post, ENDPOINT).with(headers: { "Authorization" => "Bearer private-test-key" }) do |req|
      bodies << JSON.parse(req.body)
      true
    end.to_return(status: 201, body: receipt.to_json).then.to_return(status: 200, body: receipt(duplicate: true).to_json)

    assert_equal false, publisher.call(**arguments)["duplicate"]
    assert_equal true, publisher.call(**arguments)["duplicate"]
    assert_equal bodies.first, bodies.last
    assert_equal 1, bodies.first["version"]
    assert_equal "Shipped", bodies.first.dig("report", "results", 0, "answer")
    assert_requested request, times: 2
  end

  def test_rejection_is_visible_without_echoing_credentials_or_report_content
    stub_request(:post, ENDPOINT).to_return(status: 409, body: "private-test-key Shipped")
    error = assert_raises(Publisher::Error) { publisher.call(**arguments) }
    assert_includes error.message, "HTTP 409"
    refute_includes error.message, "private-test-key"
    refute_includes error.message, "Shipped"
  end

  def test_does_not_follow_redirects_with_bearer_credentials
    stub_request(:post, ENDPOINT).to_return(status: 302, headers: { "Location" => "https://other.example.test/collect" })
    assert_raises(Publisher::Error) { publisher.call(**arguments) }
    assert_not_requested :post, "https://other.example.test/collect"
  end

  def test_timeout_fails_synchronously
    stub_request(:post, ENDPOINT).to_timeout
    assert_raises(Publisher::Error) { publisher.call(**arguments) }
  end

  def test_rejects_incomplete_and_mismatched_receipts
    [ {}, receipt.merge(run_id: "someone-else"), receipt.merge(status: "pending") ].each do |body|
      stub_request(:post, ENDPOINT).to_return(status: 200, body: body.to_json)
      assert_raises(Publisher::Error) { publisher.call(**arguments) }
    end
  end

  def test_a_name_that_does_not_resolve_fails_as_a_delivery_failure
    # SocketError is not a SystemCallError, so a DNS failure would otherwise
    # escape the documented Publisher::Error contract.
    stub_request(:post, ENDPOINT).to_raise(SocketError.new("Failed to open TCP connection"))
    error = assert_raises(Publisher::Error) { publisher.call(**arguments) }
    assert_includes error.message, "SocketError"
    assert_includes error.message, "retain the report and run_id for retry"
  end

  def test_oversized_report_never_leaves_the_process
    args = arguments.merge(report: { "answer" => "x" * Publisher::MAX_BYTES })
    assert_raises(Publisher::Error) { publisher.call(**args) }
    assert_not_requested :post, ENDPOINT
  end

  def test_requires_a_secure_destination_and_a_key
    [ "http://collector.example.test/v1/evaluations", "ftp://example.test", "https://user:pass@example.test", "https://example.test/?key=secret" ].each do |endpoint|
      assert_raises(ArgumentError) { Publisher.new(endpoint: endpoint, api_key: "test-key") }
    end
    assert_raises(ArgumentError) { Publisher.new(api_key: "") }
    assert_instance_of Publisher, Publisher.new(endpoint: "http://127.0.0.1:3210/v1/evaluations", api_key: "test-key")
  end
end
