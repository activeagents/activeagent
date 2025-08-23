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