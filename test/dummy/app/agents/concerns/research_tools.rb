# Concern that provides research-related tools that work with both
# OpenAI Responses API (built-in tools) and Chat Completions API (function calling)
module ResearchTools
  extend ActiveSupport::Concern

  included do
    # Class-level configuration for built-in tools
    class_attribute :research_tools_config, default: {}
    
    # Add default built-in tools configuration
    after_initialize :configure_research_tools
  end

  # Action methods that become function tools in Chat API
  # These are standard ActiveAgent actions that get converted to tool schemas
  
  def search_academic_papers
    @query = params[:query]
    @year_from = params[:year_from]
    @year_to = params[:year_to]
    @field = params[:field]
    
    prompt(
      message: build_academic_search_query,
      # For Responses API - add web search as built-in tool
      tools: responses_api? ? [{type: "web_search_preview", search_context_size: "high"}] : nil
    )
  end

  def analyze_research_data
    @data = params[:data]
    @analysis_type = params[:analysis_type]
    
    prompt(
      message: "Analyze the following research data:\n#{@data}\nAnalysis type: #{@analysis_type}",
      content_type: :json
    )
  end

  def generate_research_visualization
    @data = params[:data]
    @chart_type = params[:chart_type] || "bar"
    @title = params[:title]
    
    prompt(
      message: "Create a #{@chart_type} chart visualization for: #{@title}\nData: #{@data}",
      # For Responses API - add image generation as built-in tool
      tools: responses_api? ? [
        {
          type: "image_generation",
          size: "1024x1024",
          quality: "high"
        }
      ] : nil
    )
  end

  def search_with_mcp_sources
    @query = params[:query]
    @sources = params[:sources] || []
    
    # Build MCP tools configuration based on requested sources
    mcp_tools = build_mcp_tools(@sources)
    
    prompt(
      message: "Research query: #{@query}",
      tools: responses_api? ? mcp_tools : nil
    )
  end

  private

  def configure_research_tools
    # This runs after initialization to set up tool configurations
    if self.class.research_tools_config[:enable_web_search]
      # Configuration that can be set at the agent class level
      @web_search_enabled = true
    end
    
    if self.class.research_tools_config[:mcp_servers]
      @available_mcp_servers = self.class.research_tools_config[:mcp_servers]
    end
  end

  def build_academic_search_query
    query_parts = ["Academic papers search: #{@query}"]
    query_parts << "Published between #{@year_from} and #{@year_to}" if @year_from && @year_to
    query_parts << "Field: #{@field}" if @field
    query_parts << "Include citations and abstracts"
    query_parts.join("\n")
  end

  def build_mcp_tools(sources)
    tools = []
    
    sources.each do |source|
      case source
      when "arxiv"
        tools << {
          type: "mcp",
          server_label: "ArXiv Papers",
          server_url: "https://arxiv-mcp.example.com/sse",
          server_description: "Search and retrieve academic papers from ArXiv",
          require_approval: "never",
          allowed_tools: ["search_papers", "get_paper", "get_citations"]
        }
      when "pubmed"
        tools << {
          type: "mcp",
          server_label: "PubMed",
          server_url: "https://pubmed-mcp.example.com/sse",
          server_description: "Search medical and life science literature",
          require_approval: "never"
        }
      when "github"
        tools << {
          type: "mcp",
          server_label: "GitHub Research",
          server_url: "https://api.githubcopilot.com/mcp/",
          server_description: "Search code repositories and documentation",
          require_approval: "never"
        }
      end
    end
    
    tools
  end

  def responses_api?
    # Check if we're using the Responses API (multimodal or specific config)
    generation_provider.is_a?(ActiveAgent::GenerationProvider::OpenAIProvider) &&
      (@_context&.multimodal? || @_context&.options&.dig(:use_responses_api))
  end

  class_methods do
    # Class method to configure research tools for the agent
    def configure_research_tools(**options)
      self.research_tools_config = research_tools_config.merge(options)
    end
  end
end