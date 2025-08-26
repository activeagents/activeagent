class ResearchAgent < ApplicationAgent
  include ResearchTools

  # Configure the agent to use OpenAI with specific settings
  generate_with :openai, model: "gpt-4o"

  # Configure research tools at the class level
  configure_research_tools(
    enable_web_search: true,
    mcp_servers: [ "arxiv", "github" ],
    default_search_context: "high"
  )

  # Agent-specific action that uses both concern tools and custom logic
  def comprehensive_research
    @topic = params[:topic]
    @depth = params[:depth] || "detailed"

    # This action combines multiple tools
    prompt(
      message: "Conduct comprehensive research on: #{@topic}",
      tools: build_comprehensive_tools
    )
  end

  def literature_review
    @topic = params[:topic]
    @sources = params[:sources] || [ "arxiv", "pubmed" ]

    # Use the concern's search_with_mcp_sources internally
    mcp_tools = build_mcp_tools(@sources)

    prompt(
      message: "Conduct a literature review on: #{@topic}\nFocus on peer-reviewed sources from the last 5 years.",
      tools: [
        { type: "web_search_preview", search_context_size: "high" },
        *mcp_tools
      ]
    )
  end

  private

  def build_comprehensive_tools
    tools = []

    # Add web search for general information
    tools << {
      type: "web_search_preview",
      search_context_size: @depth == "detailed" ? "high" : "medium"
    }

    # Add MCP servers from configuration
    if research_tools_config[:mcp_servers]
      tools.concat(build_mcp_tools(research_tools_config[:mcp_servers]))
    end

    # Add image generation for visualizations
    if @depth == "detailed"
      tools << {
        type: "image_generation",
        size: "1024x1024",
        quality: "high"
      }
    end

    tools
  end
end
