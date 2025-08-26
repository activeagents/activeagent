# Using Concerns with ActiveAgent

Concerns provide a powerful way to share functionality, tools, and configurations across multiple agents. This guide shows how to create and use concerns effectively with ActiveAgent.

## Overview

ActiveAgent concerns work just like Rails concerns - they're modules that can be included in agents to share common functionality. This is particularly useful for:

- Sharing tool definitions across agents
- Providing common actions and prompts
- Configuring built-in tools (web search, image generation, MCP)
- Creating reusable agent capabilities

## Creating a Concern

Here's an example of a concern that provides research-related tools:

<<< @/../test/dummy/app/agents/concerns/research_tools.rb#1-126{ruby:line-numbers}

## Using Concerns in Agents

Include the concern in your agent to gain its functionality:

<<< @/../test/dummy/app/agents/research_agent.rb#1-70{ruby:line-numbers}

## Key Features

### Class-Level Configuration

Concerns can provide configuration methods that agents can use:

```ruby
module ResearchTools
  extend ActiveSupport::Concern
  
  included do
    class_attribute :research_tools_config, default: {}
  end
  
  class_methods do
    def configure_research_tools(**options)
      self.research_tools_config = research_tools_config.merge(options)
    end
  end
end

class MyResearchAgent < ApplicationAgent
  include ResearchTools
  
  configure_research_tools(
    enable_web_search: true,
    mcp_servers: ["arxiv", "github"],
    default_search_context: "high"
  )
end
```

### Actions as Tools

Public methods in concerns become available as tools for the AI:

```ruby
module DataTools
  extend ActiveSupport::Concern
  
  def calculate_statistics
    data = params[:data]
    # This becomes a tool the AI can call
    {
      mean: data.sum.to_f / data.size,
      median: data.sort[data.size / 2],
      mode: data.group_by(&:itself).values.max_by(&:size).first
    }
  end
  
  def fetch_external_data
    endpoint = params[:endpoint]
    HTTParty.get(endpoint)
  end
end
```

### Built-in Tools Configuration

Concerns can configure OpenAI's built-in tools dynamically:

```ruby
module WebSearchable
  extend ActiveSupport::Concern
  
  def search_web
    query = params[:query]
    context_size = params[:context_size] || "medium"
    
    prompt(
      message: query,
      tools: [
        {
          type: "web_search_preview",
          search_context_size: context_size
        }
      ]
    )
  end
end
```

### MCP Integration

Configure MCP (Model Context Protocol) servers in concerns:

```ruby
module MCPConnectable
  extend ActiveSupport::Concern
  
  def connect_to_services
    services = params[:services] || []
    
    mcp_tools = services.map do |service|
      case service
      when "dropbox"
        {
          type: "mcp",
          connector_id: "connector_dropbox"
        }
      when "github"
        {
          type: "mcp",
          server_url: "https://api.githubcopilot.com/mcp/"
        }
      end
    end
    
    prompt(
      message: "Connect to requested services",
      tools: mcp_tools
    )
  end
end
```

## Multiple Concerns

Agents can include multiple concerns to combine capabilities:

```ruby
class PowerfulAgent < ApplicationAgent
  include ResearchTools
  include WebSearchable
  include DataTools
  include MCPConnectable
  
  generate_with :openai, model: "gpt-4o"
  
  # This agent now has all the tools from all concerns
  def analyze_and_report
    topic = params[:topic]
    
    prompt(
      message: "Analyze #{topic} using all available tools",
      # Tools from all concerns are available
    )
  end
end
```

## Testing Concerns

Test concerns to ensure they work correctly:

```ruby
class ResearchToolsTest < ActiveSupport::TestCase
  setup do
    @agent_class = Class.new(ApplicationAgent) do
      include ResearchTools
      generate_with :openai, model: "gpt-4o"
    end
    @agent = @agent_class.new
  end
  
  test "concern adds expected actions" do
    expected_actions = [
      "search_academic_papers",
      "analyze_research_data",
      "generate_research_visualization"
    ]
    
    agent_actions = @agent.action_methods
    expected_actions.each do |action|
      assert_includes agent_actions, action
    end
  end
  
  test "concern configuration works" do
    @agent_class.configure_research_tools(
      enable_web_search: true,
      mcp_servers: ["arxiv"]
    )
    
    assert @agent_class.research_tools_config[:enable_web_search]
    assert_equal ["arxiv"], @agent_class.research_tools_config[:mcp_servers]
  end
end
```

## Best Practices

### 1. Single Responsibility

Each concern should focus on a specific capability:

```ruby
# Good - focused on research
module ResearchTools
  # Research-specific tools
end

# Good - focused on data processing
module DataProcessing
  # Data processing tools
end

# Bad - too broad
module AllTools
  # Everything mixed together
end
```

### 2. Configurable Behavior

Make concerns configurable for flexibility:

```ruby
module Translatable
  extend ActiveSupport::Concern
  
  included do
    class_attribute :translation_config, default: {}
  end
  
  class_methods do
    def configure_translation(target_languages: [], default_language: "en")
      self.translation_config = {
        target_languages: target_languages,
        default_language: default_language
      }
    end
  end
  
  def translate
    text = params[:text]
    target = params[:target] || translation_config[:default_language]
    # Translation logic
  end
end
```

### 3. Document Tool Schemas

Include JSON views for tool schemas:

```ruby
# app/views/research_tools/search_academic_papers.json.jbuilder
json.type "function"
json.function do
  json.name action_name
  json.description "Search for academic papers"
  json.parameters do
    json.type "object"
    json.properties do
      json.query do
        json.type "string"
        json.description "Search query"
      end
      json.year_from do
        json.type "integer"
        json.description "Start year for publication date filter"
      end
    end
    json.required ["query"]
  end
end
```

### 4. Handle API Differences

Consider different API capabilities:

```ruby
module AdaptiveTools
  extend ActiveSupport::Concern
  
  private
  
  def responses_api?
    # Check if using Responses API
    options[:use_responses_api] || 
    ["gpt-5", "gpt-4.1"].include?(options[:model])
  end
  
  def configure_tools
    if responses_api?
      # Use built-in tools
      [
        {type: "web_search_preview"},
        {type: "image_generation"}
      ]
    else
      # Use function calling
      []
    end
  end
end
```

## Real-World Examples

### Content Generation Concern

```ruby
module ContentGeneration
  extend ActiveSupport::Concern
  
  def generate_blog_post
    topic = params[:topic]
    style = params[:style] || "informative"
    
    prompt(
      message: "Write a #{style} blog post about #{topic}",
      instructions: "Create engaging, SEO-friendly content"
    )
  end
  
  def generate_social_media
    content = params[:content]
    platforms = params[:platforms] || ["twitter"]
    
    prompt(
      message: "Create social media posts for: #{platforms.join(', ')}",
      context: content
    )
  end
  
  def optimize_seo
    content = params[:content]
    keywords = params[:keywords]
    
    prompt(
      message: "Optimize this content for SEO",
      context: {content: content, keywords: keywords}
    )
  end
end
```

### Data Analysis Concern

```ruby
module DataAnalysis
  extend ActiveSupport::Concern
  
  included do
    class_attribute :analysis_config, default: {
      output_format: :json,
      include_visualizations: false
    }
  end
  
  def analyze_trends
    data = params[:data]
    timeframe = params[:timeframe]
    
    prompt(
      message: "Analyze trends in this data over #{timeframe}",
      content_type: analysis_config[:output_format],
      tools: visualization_tools
    )
  end
  
  private
  
  def visualization_tools
    return [] unless analysis_config[:include_visualizations]
    
    [{
      type: "image_generation",
      size: "1024x768",
      quality: "high"
    }]
  end
end
```

## Integration with Rails

Concerns work seamlessly with Rails conventions:

```ruby
# app/agents/concerns/authenticatable.rb
module Authenticatable
  extend ActiveSupport::Concern
  
  included do
    before_action :verify_authentication
  end
  
  private
  
  def verify_authentication
    unless current_user
      raise ActiveAgent::AuthenticationError, "User must be authenticated"
    end
  end
  
  def current_user
    # Access Rails current_user or implement agent-specific auth
    @current_user ||= User.find_by(id: params[:user_id])
  end
end
```

## Related Documentation

- [Testing ActiveAgent Applications](/docs/framework/testing)
- [OpenAI Provider Built-in Tools](/docs/generation-providers/openai-provider#built-in-tools-responses-api)
- [ActiveAgent Framework](/docs/framework/active-agent)