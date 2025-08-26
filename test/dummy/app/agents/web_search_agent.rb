# Example agent demonstrating web search capabilities
# Works with both Chat Completions API and Responses API
class WebSearchAgent < ApplicationAgent
  # For Chat API, use the search-preview models
  # For Responses API, use regular models with web_search_preview tool
  generate_with :openai, model: "gpt-4o"
  
  # Action for searching current events using Chat API with web search model
  def search_current_events
    @query = params[:query]
    @location = params[:location]
    
    # When using gpt-4o-search-preview model, web search is automatic
    prompt(
      message: @query,
      options: chat_api_search_options
    )
  end
  
  # Action for searching with Responses API (more flexible)
  def search_with_tools
    @query = params[:query]
    @context_size = params[:context_size] || "medium"
    
    prompt(
      message: @query,
      options: {
        use_responses_api: true,  # Force Responses API
        tools: [
          {
            type: "web_search_preview",
            search_context_size: @context_size
          }
        ]
      }
    )
  end
  
  # Action that combines web search with image generation (Responses API only)
  def research_and_visualize
    @topic = params[:topic]
    
    prompt(
      message: "Research #{@topic} and create a visualization",
      options: {
        model: "gpt-5",  # Responses API model
        use_responses_api: true,
        tools: [
          {type: "web_search_preview", search_context_size: "high"},
          {type: "image_generation", size: "1024x1024", quality: "high"}
        ]
      }
    )
  end
  
  private
  
  def chat_api_search_options
    options = {
      model: "gpt-4o-search-preview"  # Special model for Chat API web search
    }
    
    # Add web_search_options for Chat API
    if @location
      options[:web_search] = {
        user_location: format_location(@location)
      }
    else
      options[:web_search] = {}  # Enable web search with defaults
    end
    
    options
  end
  
  def format_location(location)
    # Format location for API
    {
      country: location[:country] || "US",
      city: location[:city],
      region: location[:region],
      timezone: location[:timezone]
    }.compact
  end
end