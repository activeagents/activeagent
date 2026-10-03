# frozen_string_literal: true

# An account model for the multi-tenant cases.
class ExplorationTestAccount < ActiveRecord::Base
  def self.ensure_table!
    return if connection.table_exists?(:exploration_test_accounts)

    connection.create_table(:exploration_test_accounts) { |t| t.string :name }
  end
end
ExplorationTestAccount.ensure_table!

# A project whose App assistant reaches a live sandbox that serves
# lookup_order and find_orders, for the exploration tests.
module ExplorationSetup
  RUNTIME_URL = "http://127.0.0.1:4300/activeagents/mcp"
  RUNTIME_TOKEN = "aa_runtime_explorations_s3cret"
  # Characters URL encoding and Base64 both change.
  SECRET = "sk_test_expl0ration s3cret/value+42"
  APP_TOOLS = %w[lookup_order find_orders].freeze

  def reset_exploration_records!
    [
      ActionAgent::Exploration, ActionAgent::Project, ActionAgent::ProjectSecret, ActionAgent::EvaluationScenarioResult,
      ActionAgent::EvaluationScenario, ActionAgent::EvaluationRun, ActionAgent::Evaluation, ActionAgent::Agent,
      ActionAgent::SandboxSession, ActionAgent::GithubConnection, ActionAgent::ProviderKey, ActionAgent::ApiKey
    ].each(&:delete_all)
  end

  # A project on acme/shop with a secret, its App assistant and evaluation,
  # and, unless +sandbox+ is false, a ready sandbox the assistant reaches.
  def create_explored_project!(sandbox: true)
    ActionAgent::GithubConnection.create!(
      access_token: "gho_explorationsToken0123456789", github_user_id: 7, login: "octocat",
      repositories: [ { "id" => 1, "full_name" => "acme/shop", "private" => true, "default_branch" => "main" } ]
    )
    project = ActionAgent::Project.create!(name: "Shop", repository: "acme/shop", start_url: "/")
    project.assign_secret(name: "STRIPE_SECRET_KEY", value: SECRET).save!
    project.ensure_app_assistant!
    boot_sandbox!(project) if sandbox
    project.reload
  end

  # A ready sandbox for +project+, made current and named in its agent's
  # servers, as a finished boot leaves them.
  def boot_sandbox!(project)
    sandbox = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: project.repository, project: project)
    sandbox.update!(status: :ready, runtime_mcp_url: RUNTIME_URL, runtime_mcp_token: RUNTIME_TOKEN)
    project.update!(current_sandbox_session: sandbox, status: "ready")
    project.target_agent.update!(mcp_servers: [ { "key" => sandbox.runtime_server_key, "name" => "acme/shop (sandbox)" } ])
    sandbox
  end

  # The sandbox's MCP endpoint, serving APP_TOOLS to a request with its
  # token. With +fail+ every request answers 503.
  def stub_runtime(fail: false)
    if fail
      return stub_request(:post, RUNTIME_URL).to_return(status: 503, body: "unavailable")
    end

    stub_request(:post, RUNTIME_URL)
      .with(headers: { "Authorization" => "Bearer #{RUNTIME_TOKEN}" })
      .to_return do |request|
        payload = JSON.parse(request.body)
        result =
          case payload["method"]
          when "initialize" then { protocolVersion: "2025-03-26", capabilities: { tools: {} } }
          when "tools/list"
            { tools: APP_TOOLS.map { |name| { name: name, description: "#{name} tool", inputSchema: { type: "object" } } } }
          end

        if payload.key?("id")
          { status: 200, body: { jsonrpc: "2.0", id: payload["id"], result: result }.to_json,
            headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "runtime-session" } }
        else
          { status: 202, body: "" }
        end
      end
  end

  def candidate(prompt, tools: [], rubric: nil, **extra)
    { "prompt" => prompt, "tools" => tools, "rubric" => rubric }.compact.merge(extra.stringify_keys)
  end
end
