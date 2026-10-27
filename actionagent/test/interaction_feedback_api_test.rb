# frozen_string_literal: true

require "test_helper"

class FeedbackTestAccount < ActiveRecord::Base
  self.table_name = "feedback_test_accounts"
end
unless FeedbackTestAccount.connection.table_exists?(:feedback_test_accounts)
  FeedbackTestAccount.connection.create_table(:feedback_test_accounts) { |t| t.string :telemetry_api_key }
end
# The standard dummy trace is loaded in single-tenant mode. This subclass
# supplies tenant scoping without mutating the shared trace table in tests.
class FeedbackTenantTrace < ActionAgent::TelemetryTrace
  class_attribute :visible_trace_ids, default: {}
  def self.for_account(account)
    where(id: visible_trace_ids.fetch(account&.id, []))
  end
end

class InteractionFeedbackApiTest < ActionDispatch::IntegrationTest
  def setup
    @trace = ActionAgent::TelemetryTrace.create!(trace_id: "feedback-#{SecureRandom.hex(8)}",
      spans: [ { "span_id" => "response-1", "type" => "llm" } ])
    ActionAgent.ingest_api_key = "feedback-secret"
  end

  def teardown
    ActionAgent.ingest_api_key = nil
    ActionAgent.multi_tenant = false
    ActionAgent.account_class = nil
    ActionAgent.trace_model_class = nil
    ActionAgent.current_account_resolver = nil
    FeedbackTenantTrace.visible_trace_ids = {}
  end

  def submit(overrides = {}, token: "feedback-secret", **fields)
    post "/activeagents/api/feedback", params: { feedback: {
      trace_id: @trace.trace_id, feedback_id: "vote-1", rating: "positive"
    }.merge(overrides).merge(fields) }, headers: { "Authorization" => "Bearer #{token}" }, as: :json
  end

  test "records optional comment and response span and returns them in dashboard" do
    submit(comment: "Useful", span_id: "response-1", user_reference: "user-1")
    assert_response :success
    get "/activeagents/api/feedback"
    assert_response :success
    result = response.parsed_body
    assert_equal 1, result["total"]
    assert_equal 100.0, result["positive_percentage"]
    assert_equal "Useful", result["feedback"].first["comment"]
    assert_equal @trace.trace_id, result["feedback"].first["trace_id"]
  end

  test "retries and changed ratings replace the same vote and clear comments" do
    submit(comment: "Useful")
    submit(rating: "negative", comment: nil)
    assert_response :success
    rows = ActionAgent::InteractionFeedback.where(telemetry_trace_id: @trace.id)
    assert_equal 1, rows.count
    assert_equal "negative", rows.first.rating
    assert_nil rows.first.comment
  end

  test "requires ingest authentication and validates targets and ratings" do
    submit({}, token: "wrong")
    assert_response :unauthorized
    submit(trace_id: "not-yet-ingested")
    assert_response :not_found
    submit(rating: "neutral")
    assert_response :unprocessable_entity
    submit(span_id: "unrelated")
    assert_response :unprocessable_entity
    submit(comment: "x" * 5001)
    assert_response :unprocessable_entity
    submit(feedback_id: "")
    assert_response :unprocessable_entity
    assert_equal 0, ActionAgent::InteractionFeedback.where(telemetry_trace_id: @trace.id).count
  end

  test "filters counts dates and pages without changing the denominator to a page" do
    51.times do |i|
      ActionAgent::InteractionFeedback.create!(telemetry_trace: @trace, feedback_id: "vote-#{i}", rating: i.zero? ? "negative" : "positive")
    end
    get "/activeagents/api/feedback", params: { page: 2 }
    assert_response :success
    assert_equal 51, response.parsed_body["total"]
    assert_equal 1, response.parsed_body["feedback"].size
    get "/activeagents/api/feedback", params: { rating: "negative", from: Date.current.iso8601, to: Date.current.iso8601 }
    assert_equal 1, response.parsed_body["total"]
    assert_equal 0.0, response.parsed_body["positive_percentage"]
    get "/activeagents/api/feedback", params: { from: "bad" }
    assert_response :bad_request
  end

  test "rejects malformed envelopes and returns an empty summary" do
    post "/activeagents/api/feedback", params: { feedback: "bad" },
      headers: { "Authorization" => "Bearer feedback-secret" }, as: :json
    assert_response :bad_request
    get "/activeagents/api/feedback"
    assert_equal 0, response.parsed_body["total"]
    assert_nil response.parsed_body["positive_percentage"]
    get "/activeagents/api/feedback", params: { rating: "neutral" }
    assert_response :bad_request
  end

  test "agent filtering uses the same trace identity as the traces dashboard" do
    agent = ActionAgent::Agent.create!(name: "Feedback probe", provider: "mock", model: "mock")
    @trace.update!(agent_class: agent.reported_agent_class)
    submit
    get "/activeagents/api/feedback", params: { agent_id: agent.id }
    assert_response :success
    assert_equal 1, response.parsed_body["total"]
    get "/activeagents/api/feedback", params: { agent_id: -1 }
    assert_response :not_found
  end

  test "keys and dashboard accounts cannot reach another tenant's feedback" do
    a = FeedbackTestAccount.create!(telemetry_api_key: "tenant-a")
    b = FeedbackTestAccount.create!(telemetry_api_key: "tenant-b")
    ActionAgent.multi_tenant = true
    ActionAgent.account_class = "FeedbackTestAccount"
    ActionAgent.trace_model_class = "FeedbackTenantTrace"
    FeedbackTenantTrace.visible_trace_ids = { a.id => [ @trace.id ], b.id => [] }
    submit({}, token: "tenant-b")
    assert_response :not_found
    submit({}, token: "tenant-a")
    assert_response :success
    ActionAgent.current_account_resolver = ->(_controller) { b }
    get "/activeagents/api/feedback"
    assert_response :success
    assert_equal 0, response.parsed_body["total"]
    ActionAgent.current_account_resolver = ->(_controller) { a }
    get "/activeagents/api/feedback"
    assert_equal 1, response.parsed_body["total"]
  end
end
