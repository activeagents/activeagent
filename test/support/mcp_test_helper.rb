# frozen_string_literal: true

module McpTestHelper
  # Check if an MCP server is running and available
  def mcp_server_available?(server_name)
    case server_name
    when "playwright"
      playwright_mcp_available?
    when "github"
      github_mcp_available?
    when "huggingface"
      huggingface_mcp_available?
    else
      false
    end
  end

  # Skip test unless MCP server is available
  def skip_unless_mcp_available(server_name)
    unless mcp_server_available?(server_name)
      skip "MCP server '#{server_name}' is not available. Run 'bin/setup_mcp' and start services with 'foreman start -f Procfile.dev'"
    end
  end

  private

  def playwright_mcp_available?
    # Check if playwright MCP is running by trying to connect
    # This is a simplified check - in production you might want to actually
    # attempt an MCP connection
    begin
      # Check if the MCP server process is running
      `pgrep -f "playwright-mcp" 2>/dev/null`.strip.present?
    rescue
      false
    end
  end

  def github_mcp_available?
    begin
      `pgrep -f "github-mcp" 2>/dev/null`.strip.present?
    rescue
      false
    end
  end

  def huggingface_mcp_available?
    begin
      `pgrep -f "huggingface-mcp" 2>/dev/null`.strip.present?
    rescue
      false
    end
  end
end

# Include in ActiveSupport::TestCase for all tests
ActiveSupport::TestCase.include McpTestHelper if defined?(ActiveSupport::TestCase)