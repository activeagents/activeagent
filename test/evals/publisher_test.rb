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

  def rejection(status, body)
    stub_request(:post, ENDPOINT).to_return(status: status, body: body)
    assert_raises(Publisher::Error) { publisher.call(**arguments) }
  end

  def test_a_rejection_names_what_the_collector_refused
    body = { error: "results[0].scenario_key is required", field: "scenario_key", value: "Shipped" }.to_json
    error = rejection(422, body)

    assert_equal "Evaluation delivery rejected (HTTP 422: results[0].scenario_key is required); " \
      "correct what the collector refused before retrying", error.message
    assert_equal 422, error.status
    assert_equal "results[0].scenario_key is required", error.detail
    refute error.retryable?
  end

  def test_the_collectors_explanation_is_sanitized_and_bounded
    error = rejection(422, { error: "suite\u0000\e[31m is\n\t\u202Einvalid  #{"x" * 500}" }.to_json)

    assert error.detail.start_with?("suite [31m is invalid xxx"), error.detail
    assert_equal Publisher::DETAIL_LIMIT, error.detail.length
    assert error.detail.end_with?("…"), error.detail
    refute_match(/[[:cntrl:]\u202E]/, error.message)
  end

  def test_the_api_key_is_filtered_from_the_collectors_explanation
    error = rejection(422, { error: "key private-test-key is not valid for suite orders" }.to_json)
    assert_equal "key [FILTERED] is not valid for suite orders", error.detail
    refute_includes error.message, "private-test-key"
  end

  def test_only_the_error_string_of_a_json_object_is_read
    [ "<html>Bad Gateway private-test-key</html>", "", [ "results[0] is invalid" ].to_json,
      { error: { field: "answer", value: "Shipped" } }.to_json, { message: "Shipped is invalid" }.to_json,
      { error: " \n\t " }.to_json ].each do |body|
      error = rejection(422, body)
      assert_nil error.detail, body
      assert_equal "Evaluation delivery rejected (HTTP 422); correct what the collector refused before retrying", error.message
    end
  end

  def test_a_rejection_says_whether_retrying_can_succeed
    {
      409 => [ false, "never retry this report with the same run_id" ],
      413 => [ false, "publish a smaller selection" ],
      422 => [ false, "correct what the collector refused" ],
      429 => [ true, "retry later" ],
      408 => [ true, "retain the report and run_id for retry" ],
      503 => [ true, "retain the report and run_id for retry" ],
      401 => [ false, "resolve the rejection before retrying" ]
    }.each do |status, (retryable, guidance)|
      error = rejection(status, { error: "reason #{status}" }.to_json)
      assert_equal status, error.status
      assert_equal retryable, error.retryable?, "HTTP #{status}"
      assert_includes error.message, "(HTTP #{status}: reason #{status}); "
      assert_includes error.message, guidance
    end
  end

  def test_does_not_follow_redirects_with_bearer_credentials
    stub_request(:post, ENDPOINT).to_return(status: 302, headers: { "Location" => "https://other.example.test/collect" })
    assert_raises(Publisher::Error) { publisher.call(**arguments) }
    assert_not_requested :post, "https://other.example.test/collect"
  end

  def test_timeout_fails_synchronously
    stub_request(:post, ENDPOINT).to_timeout
    error = assert_raises(Publisher::Error) { publisher.call(**arguments) }
    assert error.retryable?
    assert_nil error.status
  end

  def test_rejects_incomplete_and_mismatched_receipts
    [ {}, { error: "not a receipt" }, receipt.merge(run_id: "someone-else"), receipt.merge(status: "pending") ].each do |body|
      stub_request(:post, ENDPOINT).to_return(status: 200, body: body.to_json)
      error = assert_raises(Publisher::Error) { publisher.call(**arguments) }
      assert_equal "Evaluation collector returned an invalid completion receipt; retain the report and run_id for retry", error.message
      assert error.retryable?
      assert_nil error.status
      assert_nil error.detail
    end
  end

  def test_a_receipt_that_is_not_json_is_retryable
    stub_request(:post, ENDPOINT).to_return(status: 201, body: "<html>ok</html>")
    error = assert_raises(Publisher::Error) { publisher.call(**arguments) }
    assert_equal "Evaluation collector returned invalid JSON; retain the report and run_id for retry", error.message
    assert error.retryable?
  end

  def test_a_name_that_does_not_resolve_fails_as_a_delivery_failure
    # SocketError is not a SystemCallError, so a DNS failure would otherwise
    # escape the documented Publisher::Error contract.
    stub_request(:post, ENDPOINT).to_raise(SocketError.new("Failed to open TCP connection"))
    error = assert_raises(Publisher::Error) { publisher.call(**arguments) }
    assert_includes error.message, "SocketError"
    assert_includes error.message, "retain the report and run_id for retry"
    assert error.retryable?
  end

  def test_oversized_report_never_leaves_the_process
    args = arguments.merge(report: { "answer" => "x" * Publisher::MAX_BYTES })
    error = assert_raises(Publisher::Error) { publisher.call(**args) }
    refute error.retryable?
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
