---
title: Research Agent
description: Combine multiple tools and data sources for comprehensive research tasks. Integrates web search, MCP servers, and image generation for powerful research workflows.
---
# {{ $frontmatter.title }}

The Research Agent demonstrates how to build agents that combine multiple tools and data sources for comprehensive research tasks. It shows integration with web search, MCP servers, and image generation to create powerful research workflows.

## Overview

The Research Agent showcases:
- **Multi-Tool Integration** - Combining web search, MCP, and image generation
- **Concern-Based Architecture** - Using concerns to share research functionality
- **Configurable Tools** - Dynamic tool configuration based on research needs
- **Academic Sources** - Integration with ArXiv, PubMed, and other research databases

## Features

- **Web Search Integration** - Access current information via web search
- **MCP Server Support** - Connect to academic databases (ArXiv, GitHub, PubMed)
- **Image Generation** - Create visualizations for research findings
- **Configurable Depth** - Adjust research comprehensiveness (quick vs. detailed)
- **Literature Review** - Specialized action for academic research
- **Source Citation** - Track and cite research sources

## Setup

Generate a research agent:

```bash
rails generate active_agent:agent research comprehensive_research literature_review
```

## Agent Implementation

```ruby
class ResearchAgent < ApplicationAgent
  include ResearchTools

  # Configure the agent to use OpenAI with specific settings
  generate_with :openai, model: "gpt-4o"

  # Configure research tools at the class level
  configure_research_tools(
    enable_web_search: true,
    mcps: ["arxiv", "github"],
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
    @sources = params[:sources] || ["arxiv", "pubmed"]

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

  def build_mcp_tools(sources)
    sources.map do |source|
      {
        type: "mcp",
        server_label: source.titleize,
        server_url: mcp_server_url(source)
      }
    end
  end

  def mcp_server_url(source)
    # Map source names to MCP server URLs
    urls = {
      "arxiv" => "https://api.arxiv.org/mcp/",
      "github" => "https://api.githubcopilot.com/mcp/",
      "pubmed" => "https://api.pubmed.gov/mcp/"
    }
    urls[source]
  end

  def research_tools_config
    self.class.research_tools_config || {}
  end
end
```

### Research Tools Concern

Share research functionality across agents:

```ruby
# app/agents/concerns/research_tools.rb
module ResearchTools
  extend ActiveSupport::Concern

  class_methods do
    def configure_research_tools(config = {})
      @research_tools_config = config
    end

    def research_tools_config
      @research_tools_config || {}
    end
  end

  def search_academic_papers
    @query = params[:query]
    @sources = params[:sources] || ["arxiv"]

    prompt(
      message: "Search for academic papers about: #{@query}",
      tools: build_mcp_tools(@sources)
    )
  end

  def analyze_research_data
    @data = params[:data]
    @analysis_type = params[:analysis_type] || "statistical"

    prompt(
      message: "Analyze the following research data using #{@analysis_type} methods:\n\n#{@data}"
    )
  end

  def generate_research_visualization
    @topic = params[:topic]
    @style = params[:style] || "infographic"

    prompt(
      message: "Create a #{@style} visualization for: #{@topic}",
      tools: [
        {
          type: "image_generation",
          size: "1024x1024",
          quality: "high"
        }
      ]
    )
  end
end
```

## Usage Examples

### Comprehensive Research

Conduct multi-source research on a topic:

```ruby
response = ResearchAgent.with(
  topic: "quantum computing advances in 2025",
  depth: "detailed"
).comprehensive_research.generate_now

puts response.message.content
# => Returns comprehensive research with web sources, academic papers, and visualizations
```

### Quick Research

For faster, less comprehensive research:

```ruby
response = ResearchAgent.with(
  topic: "Ruby on Rails 8 features",
  depth: "quick"
).comprehensive_research.generate_now

puts response.message.content
# => Returns focused research with medium-depth web search
```

### Literature Review

Focus on academic sources for scholarly research:

```ruby
response = ResearchAgent.with(
  topic: "machine learning in healthcare",
  sources: ["arxiv", "pubmed"]
).literature_review.generate_now

puts response.message.content
# => Returns peer-reviewed research from ArXiv and PubMed
```

### Custom Sources

Specify specific research databases:

```ruby
response = ResearchAgent.with(
  topic: "climate change models",
  sources: ["arxiv", "github"]  # Academic papers + code repositories
).literature_review.generate_now

puts response.message.content
# => Combines academic papers with open-source implementations
```

## Research Tools Configuration

### Class-Level Configuration

Configure default research settings:

```ruby
class ResearchAgent < ApplicationAgent
  configure_research_tools(
    enable_web_search: true,
    mcps: ["arxiv", "github", "pubmed"],
    default_search_context: "high",
    enable_visualizations: true
  )
end
```

### Runtime Configuration

Override defaults for specific requests:

```ruby
response = ResearchAgent.with(
  topic: "topic",
  depth: "detailed",  # Override default depth
  sources: ["arxiv"]  # Override default MCP servers
).comprehensive_research.generate_now
```

## Tool Combinations

### Web Search + Academic Sources

Combine current information with peer-reviewed research:

```ruby
tools = [
  { type: "web_search_preview", search_context_size: "high" },
  { type: "mcp", server_label: "ArXiv", server_url: "..." },
  { type: "mcp", server_label: "PubMed", server_url: "..." }
]

prompt(message: "Research topic", tools: tools)
```

### Research + Visualization

Include image generation for data visualization:

```ruby
tools = [
  { type: "web_search_preview", search_context_size: "high" },
  { type: "image_generation", size: "1024x1024", quality: "high" }
]

prompt(
  message: "Research #{topic} and create an infographic",
  tools: tools
)
```

### GitHub + Academic Papers

Combine theory with practical implementations:

```ruby
tools = [
  { type: "mcp", server_label: "ArXiv", server_url: "..." },  # Papers
  { type: "mcp", server_label: "GitHub", server_url: "..." }  # Code
]

prompt(
  message: "Find papers and implementations for #{algorithm}",
  tools: tools
)
```

## Academic Source Integration

### ArXiv Integration

Search academic papers on ArXiv:

```ruby
{
  type: "mcp",
  server_label: "ArXiv",
  server_url: "https://api.arxiv.org/mcp/",
  server_description: "Academic papers in physics, math, CS, and more"
}
```

### PubMed Integration

Access medical and life sciences research:

```ruby
{
  type: "mcp",
  server_label: "PubMed",
  server_url: "https://api.pubmed.gov/mcp/",
  server_description: "Biomedical literature database"
}
```

### GitHub Integration

Find open-source implementations:

```ruby
{
  type: "mcp",
  server_label: "GitHub",
  server_url: "https://api.githubcopilot.com/mcp/",
  server_description: "Code repositories and implementations"
}
```

## Using Concerns for Shared Functionality

### Creating a Research Concern

```ruby
# app/agents/concerns/research_tools.rb
module ResearchTools
  extend ActiveSupport::Concern

  included do
    class_attribute :research_tools_config, default: {}
  end

  class_methods do
    def configure_research_tools(config = {})
      self.research_tools_config = config
    end
  end

  # Shared research actions
  def search_papers
    # Implementation
  end

  def analyze_data
    # Implementation
  end
end
```

### Using the Concern

```ruby
class ResearchAgent < ApplicationAgent
  include ResearchTools

  configure_research_tools(
    enable_web_search: true,
    mcps: ["arxiv"]
  )
end

class AcademicAgent < ApplicationAgent
  include ResearchTools

  configure_research_tools(
    enable_web_search: false,
    mcps: ["arxiv", "pubmed"]
  )
end
```

## Integration Patterns

### Controller Integration

Use research agents in your application:

```ruby
class ResearchController < ApplicationController
  def research
    response = ResearchAgent.with(
      topic: params[:topic],
      depth: params[:depth] || "detailed"
    ).comprehensive_research.generate_now

    render json: {
      topic: params[:topic],
      findings: response.message.content,
      sources: extract_sources(response)
    }
  end

  private

  def extract_sources(response)
    # Extract citations and sources from response
    response.message.content.scan(/\[(\d+)\]/).flatten
  end
end
```

### Background Jobs

Process research asynchronously:

```ruby
class ResearchJob < ApplicationJob
  queue_as :default

  def perform(topic, user_id)
    response = ResearchAgent.with(
      topic: topic,
      depth: "detailed"
    ).comprehensive_research.generate_now

    # Save results
    ResearchResult.create!(
      user_id: user_id,
      topic: topic,
      findings: response.message.content
    )

    # Notify user
    UserMailer.research_complete(user_id, topic).deliver_later
  end
end
```

### Caching Research

Cache expensive research operations:

```ruby
class ResearchAgent < ApplicationAgent
  def cached_research
    @topic = params[:topic]
    cache_key = "research:#{Digest::MD5.hexdigest(@topic)}"

    Rails.cache.fetch(cache_key, expires_in: 24.hours) do
      comprehensive_research.generate_now
    end
  end
end
```

## Advanced Features

### Progressive Research

Build up research incrementally:

```ruby
def progressive_research
  @topic = params[:topic]
  results = []

  # Step 1: Quick web search
  results << quick_search(@topic)

  # Step 2: Academic papers
  results << search_papers(@topic)

  # Step 3: Code examples
  results << search_code(@topic)

  # Step 4: Synthesize findings
  synthesize_results(results)
end
```

### Source Prioritization

Prioritize certain sources:

```ruby
def prioritized_research
  @topic = params[:topic]

  # Try academic sources first
  response = search_academic_only(@topic)

  # Fall back to web search if insufficient
  if response.confidence < 0.7
    response = add_web_search(response, @topic)
  end

  response
end
```

### Citation Extraction

Extract and format citations:

```ruby
def extract_citations(response)
  citations = []

  response.prompt.messages.each do |message|
    next unless message.role == :tool
    next unless message.content.include?("arxiv") || message.content.include?("pubmed")

    citations << parse_citation(message.content)
  end

  citations
end

def parse_citation(content)
  # Extract title, authors, date, DOI, etc.
  {
    title: extract_title(content),
    authors: extract_authors(content),
    year: extract_year(content),
    doi: extract_doi(content)
  }
end
```

## Testing

### Test Research Workflow

```ruby
class ResearchAgentTest < ActiveSupport::TestCase
  test "conducts comprehensive research" do
    VCR.use_cassette("research_comprehensive") do
      response = ResearchAgent.with(
        topic: "test topic",
        depth: "detailed"
      ).comprehensive_research.generate_now

      assert response.message.content.present?
      assert response.message.content.length > 500  # Substantial content
    end
  end

  test "performs literature review" do
    response = ResearchAgent.with(
      topic: "machine learning",
      sources: ["arxiv"]
    ).literature_review.generate_now

    assert response.message.content.present?
    # Check that academic sources were used
    tool_messages = response.prompt.messages.select { |m| m.role == :tool }
    assert tool_messages.any? { |m| m.content.include?("arxiv") }
  end
end
```

### Mock External Services

```ruby
class ResearchAgentTest < ActiveSupport::TestCase
  setup do
    @mock_arxiv_response = {
      papers: [
        { title: "Test Paper", authors: "Author", year: 2025 }
      ]
    }
  end

  test "handles mock MCP responses" do
    # Mock MCP server responses
    stub_request(:post, "https://api.arxiv.org/mcp/")
      .to_return(body: @mock_arxiv_response.to_json)

    response = ResearchAgent.with(
      topic: "test",
      sources: ["arxiv"]
    ).literature_review.generate_now

    assert response.message.content.include?("Test Paper")
  end
end
```

## Best Practices

### Source Selection

Choose appropriate sources for your research:

- **ArXiv**: Physics, mathematics, computer science
- **PubMed**: Medical and life sciences
- **GitHub**: Code implementations and examples
- **Web Search**: Current events and general information

### Depth Configuration

Balance comprehensiveness with speed:

```ruby
# Quick research (< 30 seconds)
depth: "quick"         # Medium web search, no visualizations

# Standard research (30-60 seconds)
depth: "standard"      # High web search, basic MCP

# Detailed research (1-2 minutes)
depth: "detailed"      # High web search, multiple MCP, visualizations
```

### Result Validation

Validate research quality:

```ruby
def validate_research(response)
  content = response.message.content

  # Check for minimum content length
  return false if content.length < 500

  # Check for citations
  return false unless content.include?("[") && content.include?("]")

  # Check for multiple sources
  tool_messages = response.prompt.messages.select { |m| m.role == :tool }
  return false if tool_messages.length < 2

  true
end
```

## Conclusion

The Research Agent demonstrates how to build sophisticated research workflows by combining multiple tools and data sources. Through concern-based architecture and configurable tool selection, it provides a flexible foundation for academic research, technical investigations, and comprehensive information gathering tasks.
