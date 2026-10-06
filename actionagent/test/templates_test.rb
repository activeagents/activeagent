# frozen_string_literal: true

require "test_helper"

# The template library on the engine (#391, #113): it seeds itself, "Use This
# Template" works with no user model configured, and the agent it returns is
# the full record the editor initializes from.
class TemplatesTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::AgentTemplate.delete_all
    ActionAgent::Agent.delete_all
  end

  test "the library seeds its defaults on first read" do
    get "/activeagents/api/templates"

    assert_response :success
    assert JSON.parse(response.body)["templates"].any?, "a fresh install showed an empty library"
    assert ActionAgent::AgentTemplate.exists?(slug: "playwright-mcp-demo")
  end

  test "seeding is idempotent" do
    ActionAgent::AgentTemplate.seed_defaults!
    count = ActionAgent::AgentTemplate.count

    ActionAgent::AgentTemplate.seed_defaults!

    assert_equal count, ActionAgent::AgentTemplate.count
  end

  test "using a template creates an agent with no user configured" do
    ActionAgent::AgentTemplate.seed_defaults!
    template = ActionAgent::AgentTemplate.find_by!(slug: "code-assistant")

    assert_difference -> { ActionAgent::Agent.count }, 1 do
      post "/activeagents/api/templates/#{template.id}/use", params: { name: "Probe Agent" }
    end

    assert_response :created
    agent = JSON.parse(response.body)["agent"]
    assert_equal "Probe Agent", agent["name"]
    # The detail shape, so the editor never seeds an empty form from it.
    assert_equal template.instructions, agent["instructions"]
    assert_equal template.tools, agent["tools"]
    assert_equal template.model_config, agent["model_config"]
    assert agent.key?("action_prompts")
    assert_equal 1, template.reload.usage_count
  end

  test "the template's name is used when none is given" do
    ActionAgent::AgentTemplate.seed_defaults!
    template = ActionAgent::AgentTemplate.find_by!(slug: "code-assistant")

    post "/activeagents/api/templates/#{template.id}/use"

    assert_response :created
    assert_equal template.name, JSON.parse(response.body).dig("agent", "name")
  end

  test "an agent created from the Playwright template does not break the tool inventory" do
    ActionAgent::AgentTemplate.seed_defaults!
    template = ActionAgent::AgentTemplate.find_by!(slug: "playwright-mcp-demo")

    post "/activeagents/api/templates/#{template.id}/use", params: { name: "Browser Probe" }
    assert_response :created

    get "/activeagents/api/tools"
    assert_response :success

    get "/activeagents/api/mcp_servers"
    assert_response :success
    playwright = JSON.parse(response.body)["servers"].find { |server| server["key"] == "playwright" }
    assert_includes playwright["configured_by"], "Browser Probe"
  end

  test "the Playwright demo template names the published Playwright MCP package" do
    ActionAgent::AgentTemplate.seed_defaults!
    server = ActionAgent::AgentTemplate.find_by!(slug: "playwright-mcp-demo").mcp_servers.first.to_h.transform_keys(&:to_s)

    assert_equal "npx", server["command"]
    assert_equal [ "-y", "@playwright/mcp@latest" ], server["args"]
  end

  # The conference demo: registers in the platform's browser, stops at
  # payment, hands the page to a person.
  test "the conference ticket template drives the browser and can hand off before paying" do
    ActionAgent::AgentTemplate.seed_defaults!
    template = ActionAgent::AgentTemplate.find_by!(slug: "conference-ticket")

    assert_includes template.tools, "playwright_mcp"
    tool_names = ActionAgent::AgentToolbox.definitions_for(template.tools).map { |tool| tool[:name] }
    assert_includes tool_names, "request_handoff"
    assert_includes tool_names, "browser_navigate"
    assert_match(/Never enter payment details/, template.instructions)
    assert_match(/call request_handoff/, template.instructions)

    post "/activeagents/api/templates/#{template.id}/use", params: { name: "SF Ruby Ticket Agent" }

    assert_response :created
    agent = JSON.parse(response.body)["agent"]
    assert_equal template.tools, agent["tools"]
    assert_equal template.instructions, agent["instructions"]
  end
end
