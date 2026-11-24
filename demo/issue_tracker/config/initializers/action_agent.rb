# frozen_string_literal: true

ActionAgent.configure do |config|
  # A demo on a laptop: no sign-in. With this unset the dashboard is open in
  # development and test, and answers 403 everywhere else.
  config.authentication_method = nil

  # The tools the agent editor offers, named explicitly because two of the
  # classes concern issues: IssueTools reads, IssueActionTools writes.
  config.schema_tools = %w[IssueTools UserTools IssueActionTools]

  # The dashboard is also an MCP server. Keep the tools above reachable only
  # through an agent, so an API key alone cannot change an issue.
  config.mcp_schema_tools = false
end
