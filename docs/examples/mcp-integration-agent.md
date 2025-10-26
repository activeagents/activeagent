---
title: MCP Integration Agent
---
# {{ $frontmatter.title }}

The Model Context Protocol (MCP) Integration Agent demonstrates how to connect ActiveAgent with external services and tools through MCP. MCP provides a standardized way to integrate with cloud storage, APIs, and custom services.

## Overview

MCP enables agents to:
- Connect to cloud storage services (Dropbox, Google Drive, SharePoint, etc.)
- Access external APIs and databases
- Use custom MCP servers for specialized functionality
- Combine multiple data sources in a single agent

## Features

- **Cloud Storage Connectors** - Pre-built connectors for popular services
- **Custom MCP Servers** - Connect to your own MCP-compatible services
- **Multi-Source Search** - Combine multiple MCP servers in one query
- **Approval Workflows** - Control which operations require user approval
- **Secure Authorization** - Handle authentication tokens securely

## Setup

Generate an MCP integration agent:

```bash
rails generate active_agent:agent mcp_integration search_cloud_storage
```

## Agent Implementation

```ruby
# Example agent demonstrating MCP (Model Context Protocol) integration
# MCP allows connecting to external services and tools
class McpIntegrationAgent < ApplicationAgent
  generate_with :openai, model: "gpt-5"  # Responses API required for MCP

  # Use MCP connectors for cloud storage services
  def search_cloud_storage
    @query = params[:query]
    @service = params[:service] || "dropbox"
    @auth_token = params[:auth_token]

    prompt(
      message: "Search for: #{@query}",
      options: {
        use_responses_api: true,
        tools: [build_connector_tool(@service, @auth_token)]
      }
    )
  end

  # Use custom MCP server for specialized functionality
  def use_custom_mcp
    @query = params[:query]
    @server_url = params[:server_url]
    @allowed_tools = params[:allowed_tools]

    prompt(
      message: @query,
      options: {
        use_responses_api: true,
        tools: [
          {
            type: "mcp",
            server_label: "Custom MCP Server",
            server_url: @server_url,
            server_description: "Custom MCP server for specialized tasks",
            require_approval: "always",  # Require approval for safety
            allowed_tools: @allowed_tools
          }
        ]
      }
    )
  end

  # Combine multiple MCP servers for comprehensive search
  def multi_source_search
    @query = params[:query]
    @sources = params[:sources] || ["github", "dropbox"]
    @auth_tokens = params[:auth_tokens] || {}

    tools = @sources.map do |source|
      case source
      when "github"
        {
          type: "mcp",
          server_label: "GitHub",
          server_url: "https://api.githubcopilot.com/mcp/",
          server_description: "Search GitHub repositories",
          require_approval: "never"
        }
      when "dropbox"
        build_connector_tool("dropbox", @auth_tokens["dropbox"])
      when "google_drive"
        build_connector_tool("google_drive", @auth_tokens["google_drive"])
      end
    end.compact

    prompt(
      message: "Search across multiple sources: #{@query}",
      options: {
        use_responses_api: true,
        tools: tools
      }
    )
  end

  # Use MCP with approval workflow
  def sensitive_operation
    @operation = params[:operation]
    @mcp_config = params[:mcp_config]

    prompt(
      message: "Perform operation: #{@operation}",
      options: {
        use_responses_api: true,
        tools: [
          {
            type: "mcp",
            server_label: @mcp_config[:label],
            server_url: @mcp_config[:url],
            authorization: @mcp_config[:auth],
            require_approval: {
              never: {
                tool_names: ["read", "search"]  # Safe operations
              }
            }
            # All other operations will require approval
          }
        ]
      }
    )
  end

  private

  def build_connector_tool(service, auth_token)
    connector_configs = {
      "dropbox" => {
        connector_id: "connector_dropbox",
        label: "Dropbox"
      },
      "google_drive" => {
        connector_id: "connector_googledrive",
        label: "Google Drive"
      },
      "gmail" => {
        connector_id: "connector_gmail",
        label: "Gmail"
      },
      "sharepoint" => {
        connector_id: "connector_sharepoint",
        label: "SharePoint"
      },
      "outlook" => {
        connector_id: "connector_outlookemail",
        label: "Outlook Email"
      }
    }

    config = connector_configs[service]
    return nil unless config && auth_token

    {
      type: "mcp",
      server_label: config[:label],
      connector_id: config[:connector_id],
      authorization: auth_token,
      require_approval: "never"  # Or configure based on your needs
    }
  end
end
```

## Usage Examples

### Search Cloud Storage

Search for files across cloud storage services:

```ruby
response = McpIntegrationAgent.with(
  query: "Q4 2024 financial report",
  service: "dropbox",
  auth_token: user.dropbox_token
).search_cloud_storage.generate_now

puts response.message.content
# => Returns information about matching files in Dropbox
```

### Multi-Source Search

Search across multiple services simultaneously:

```ruby
response = McpIntegrationAgent.with(
  query: "project documentation",
  sources: ["github", "google_drive", "dropbox"],
  auth_tokens: {
    "google_drive" => user.google_token,
    "dropbox" => user.dropbox_token
  }
).multi_source_search.generate_now

puts response.message.content
# => Returns results from all three sources
```

### Custom MCP Server

Connect to your own MCP-compatible service:

```ruby
response = McpIntegrationAgent.with(
  query: "customer support tickets from last week",
  server_url: "https://api.mycompany.com/mcp",
  allowed_tools: ["search_tickets", "get_ticket_details"]
).use_custom_mcp.generate_now

puts response.message.content
# => Returns ticket information from custom server
```

### Approval Workflow

Control which operations require user approval:

```ruby
response = McpIntegrationAgent.with(
  operation: "analyze sales data",
  mcp_config: {
    label: "Company Database",
    url: "https://db.company.com/mcp",
    auth: database_token
  }
).sensitive_operation.generate_now

# Read operations execute automatically
# Write/delete operations will require approval
```

## Cloud Storage Connectors

### Supported Services

ActiveAgent provides pre-built connectors for:

- **Dropbox** - `connector_dropbox`
- **Google Drive** - `connector_googledrive`
- **Gmail** - `connector_gmail`
- **SharePoint** - `connector_sharepoint`
- **Outlook** - `connector_outlookemail`

### Configuration

Each connector requires:

```ruby
{
  type: "mcp",
  server_label: "Service Name",      # Display name
  connector_id: "connector_service", # Connector identifier
  authorization: "user_auth_token",  # User's OAuth token
  require_approval: "never"          # Approval policy
}
```

### Authentication

Handle OAuth tokens securely:

```ruby
class McpIntegrationAgent < ApplicationAgent
  before_action :validate_tokens

  private

  def validate_tokens
    service = params[:service]
    token = params[:auth_token]

    unless token.present? && valid_token?(token, service)
      raise "Invalid or missing authentication token for #{service}"
    end
  end

  def valid_token?(token, service)
    # Verify token is valid and not expired
    TokenValidator.valid?(token, service)
  end
end
```

## Custom MCP Servers

### Server Configuration

Connect to custom MCP-compatible servers:

```ruby
{
  type: "mcp",
  server_label: "My Custom Server",
  server_url: "https://api.example.com/mcp/",
  server_description: "Description of what this server does",
  authorization: auth_token,
  require_approval: "always",  # or "never"
  allowed_tools: ["tool1", "tool2"]  # Optional: restrict available tools
}
```

### Building Custom MCP Servers

Your custom MCP server should implement:

1. **Tool Discovery** - Endpoint to list available tools
2. **Tool Execution** - Endpoint to execute tool calls
3. **Authentication** - Support for authorization tokens
4. **Error Handling** - Proper error responses

Example server structure:

```ruby
# lib/mcp_server.rb
class McpServer
  def tools
    [
      {
        name: "search_database",
        description: "Search the company database",
        parameters: {
          type: "object",
          properties: {
            query: { type: "string", description: "Search query" },
            limit: { type: "integer", description: "Max results" }
          },
          required: ["query"]
        }
      }
    ]
  end

  def execute_tool(name, params)
    case name
    when "search_database"
      Database.search(params["query"], limit: params["limit"])
    else
      { error: "Unknown tool: #{name}" }
    end
  end
end
```

## Approval Workflows

### Approval Policies

Control which operations require user approval:

```ruby
{
  require_approval: {
    never: {
      tool_names: ["read", "search", "list"]  # Safe read-only operations
    }
    # All other operations will require approval
  }
}
```

### Approval Options

- **"never"** - All operations execute automatically (use with caution)
- **"always"** - All operations require approval (safest)
- **Custom** - Specify which tools don't require approval

### Implementing Approval UI

```ruby
class McpApprovalsController < ApplicationController
  def show
    @approval_request = ApprovalRequest.find(params[:id])
  end

  def approve
    approval = ApprovalRequest.find(params[:id])
    approval.approve!

    # Resume agent execution
    agent = McpIntegrationAgent.new
    response = agent.resume_with_approval(approval)

    redirect_to chat_path, notice: "Operation approved"
  end

  def reject
    approval = ApprovalRequest.find(params[:id])
    approval.reject!

    redirect_to chat_path, notice: "Operation rejected"
  end
end
```

## Security Considerations

### Token Management

Store and handle authentication tokens securely:

```ruby
class User < ApplicationRecord
  # Encrypt tokens at rest
  encrypts :dropbox_token
  encrypts :google_token

  # Validate token before use
  def valid_dropbox_token?
    return false unless dropbox_token.present?
    return false if dropbox_token_expired?
    true
  end

  def dropbox_token_expired?
    # Check token expiration
    dropbox_token_expires_at < Time.current
  end
end
```

### Scope Limiting

Request only necessary permissions:

```ruby
# config/initializers/oauth.rb
DROPBOX_SCOPES = %w[
  files.metadata.read
  files.content.read
  # Don't request write/delete unless needed
].freeze
```

### Audit Logging

Log all MCP operations for security auditing:

```ruby
class McpIntegrationAgent < ApplicationAgent
  after_action :log_mcp_operation

  private

  def log_mcp_operation
    McpAuditLog.create!(
      user_id: params[:user_id],
      service: params[:service],
      operation: action_name,
      query: params[:query],
      timestamp: Time.current
    )
  end
end
```

## Integration Patterns

### User-Scoped Tokens

Use per-user authentication:

```ruby
class ChatController < ApplicationController
  def message
    response = McpIntegrationAgent.with(
      query: params[:query],
      service: params[:service],
      auth_token: current_user.token_for(params[:service])
    ).search_cloud_storage.generate_now

    render json: { message: response.message.content }
  end
end
```

### Service Discovery

Dynamically discover available services:

```ruby
class McpIntegrationAgent < ApplicationAgent
  def available_services
    user = User.find(params[:user_id])

    services = []
    services << "dropbox" if user.dropbox_token.present?
    services << "google_drive" if user.google_token.present?
    services << "github" if user.github_token.present?

    services
  end
end
```

### Fallback Handling

Handle service unavailability gracefully:

```ruby
def multi_source_search
  tools = @sources.map do |source|
    build_connector_tool(source, @auth_tokens[source])
  end.compact  # Remove nil values for unavailable services

  if tools.empty?
    raise "No services available. Please connect at least one service."
  end

  prompt(
    message: @query,
    options: {
      use_responses_api: true,
      tools: tools
    }
  )
end
```

## Testing

### Mock MCP Responses

```ruby
class McpIntegrationAgentTest < ActiveSupport::TestCase
  test "searches cloud storage" do
    VCR.use_cassette("mcp_dropbox_search") do
      response = McpIntegrationAgent.with(
        query: "test file",
        service: "dropbox",
        auth_token: "test_token"
      ).search_cloud_storage.generate_now

      assert response.message.content.present?
    end
  end

  test "combines multiple sources" do
    response = McpIntegrationAgent.with(
      query: "documentation",
      sources: ["github"],
      auth_tokens: {}
    ).multi_source_search.generate_now

    assert response.message.content.present?
  end
end
```

## Rate Limiting

Implement rate limiting for MCP operations:

```ruby
class McpIntegrationAgent < ApplicationAgent
  before_action :check_mcp_rate_limit

  private

  def check_mcp_rate_limit
    service = params[:service]
    user_id = params[:user_id]
    key = "mcp_rate:#{user_id}:#{service}"

    count = Rails.cache.increment(key, 1, expires_in: 1.hour)

    if count > 50  # 50 requests per hour per service
      raise "Rate limit exceeded for #{service}"
    end
  end
end
```

## Provider Requirements

MCP integration requires:

- **Responses API** - MCP is only available with Responses API
- **Compatible Models** - gpt-5 or newer
- **OpenAI Provider** - Currently OpenAI-specific

```ruby
# config/application.rb
config.active_agent.providers = {
  openai: {
    api_key: ENV["OPENAI_API_KEY"],
    use_responses_api: true  # Required for MCP
  }
}
```

## Conclusion

The MCP Integration Agent demonstrates how to connect ActiveAgent with external services and data sources. Whether using pre-built cloud storage connectors or custom MCP servers, MCP provides a standardized, secure way to extend your agents' capabilities beyond their training data and into your organization's systems and data.
