# frozen_string_literal: true
require "test_helper"

class ActivePromptRoutesTest < ActionDispatch::IntegrationTest
  test "engine mounted health endpoint responds ok" do
    get "/active_prompt/health"
    assert_response :success
    assert_equal "ok", @response.body
  end

  test "engine defines a named :health route with path /health" do
    named  = ActivePrompt::Engine.routes.named_routes
    assert named.key?(:health), "Expected engine to define a :health named route"

    route  = named[:health]
    actual = route.path.spec.to_s.sub(/\(\.:format\)\z/, "")  # <-- strip optional format
    assert_equal "/health", actual
  end
end
