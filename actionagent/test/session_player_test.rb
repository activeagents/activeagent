# frozen_string_literal: true

require "test_helper"

# The frame the session player runs in: the replay bundle, a policy that
# keeps a replayed page inert, and no data.
class SessionPlayerTest < ActionDispatch::IntegrationTest
  def teardown
    ActionAgent.authentication_method = nil
  end

  test "serves the replay bundle under a policy that allows no other script and loads nothing" do
    get "/activeagents/session_player"

    assert_response :success
    script = "http://www.example.com/action_agent_replay.js"
    assert_equal ActionAgent::SessionPlayerController.policy(script), response.headers["Content-Security-Policy"]
    policy = response.headers["Content-Security-Policy"].split("; ")
    assert_includes policy, "default-src 'none'"
    assert_includes policy, "script-src #{script}"
    assert_includes policy, "img-src data: blob:"
    assert_equal "SAMEORIGIN", response.headers["X-Frame-Options"]
  end

  test "loads the bundle by its asset path, so the page's own scheme is kept" do
    get "/activeagents/session_player"

    assert_includes response.body, %(<script src="/action_agent_replay.js"></script>)
    assert_includes response.headers["Content-Security-Policy"].split("; "), "script-src http://www.example.com/action_agent_replay.js"
  end

  test "the frame carries no data" do
    get "/activeagents/session_player"

    assert_equal 1, response.body.scan("<script").size
    assert_not_includes response.body, "data-props"
    assert_not_includes response.body, "csrf"
    assert_not_includes response.body, "action_agent.js"
  end

  test "is not served to a caller the host does not authenticate" do
    ActionAgent.authentication_method = ->(_controller) { false }

    get "/activeagents/session_player"

    assert_response :unauthorized
  end

  test "the policy names a bundle on an asset host by its full URL" do
    assert_equal "default-src 'none'; script-src https://cdn.example.com/assets/action_agent_replay-1a2b.js; " \
      "style-src 'unsafe-inline'; img-src data: blob:; font-src data:; base-uri 'none'; form-action 'none'; " \
      "frame-ancestors 'self'",
      ActionAgent::SessionPlayerController.policy("https://cdn.example.com/assets/action_agent_replay-1a2b.js")
  end

  test "the policy names the bundle without its query" do
    policy = ActionAgent::SessionPlayerController.policy("https://cdn.example.com/assets/action_agent_replay.js?v=3")

    assert_includes policy.split("; "), "script-src https://cdn.example.com/assets/action_agent_replay.js"
  end

  test "a Sprockets host precompiles the replay bundle with the dashboard's" do
    assets = ActiveSupport::OrderedOptions.new
    assets.paths = []
    assets.precompile = []
    app = Struct.new(:config).new(Struct.new(:assets).new(assets))

    ActionAgent::Engine.instance.initializers.find { |initializer| initializer.name == "action_agent.assets" }.run(app)

    assert_equal %w[action_agent.js action_agent.css action_agent_replay.js], assets.precompile
    assert_equal [ ActionAgent::Engine.root.join("app", "assets", "builds").to_s ], assets.paths
  end
end
