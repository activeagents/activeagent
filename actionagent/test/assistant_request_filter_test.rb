# frozen_string_literal: true

require "test_helper"

class AssistantRequestFilterTest < ActiveSupport::TestCase
  test "request logs hide assistant query strings and bodies under any mount without changing input" do
    paths = [ "/activeagents/api/dashboard_assistant", "/admin/agents/api/dashboard_assistant.json", "/api/dashboard_assistant/", "/api/dashboard_assistant.html" ]
    paths.each do |path|
      env = Rack::MockRequest.env_for("#{path}?message=private-question&history=private-report&credential=private-key&provider=openai")
      filters = [ :credential ]
      env["action_dispatch.parameter_filter"] = filters
      downstream = ->(request_env) {
        request = ActionDispatch::Request.new(request_env)
        assert_not_includes request.filtered_path, "private-"
        assert_not_includes request.filtered_parameters.to_json, "private-"
        assert_equal "private-question", request.params["message"]
        assert_equal "openai", request.filtered_parameters["provider"]
        [ 200, {}, [] ]
      }
      ActionAgent::AssistantRequestFilter.new(downstream).call(env)
      assert_equal [ :credential ], filters
    end
  end

  test "unrelated host requests keep their existing logging policy" do
    env = Rack::MockRequest.env_for("/messages?message=host-message&history=host-history")
    downstream = ->(request_env) {
      request = ActionDispatch::Request.new(request_env)
      assert_equal "host-message", request.filtered_parameters["message"]
      assert_equal "host-history", request.filtered_parameters["history"]
      [ 200, {}, [] ]
    }
    ActionAgent::AssistantRequestFilter.new(downstream).call(env)
  end
end
