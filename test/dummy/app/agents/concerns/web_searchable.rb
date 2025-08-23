module WebSearchable
  extend ActiveSupport::Concern

  included do
    # Add web search built-in tool when this concern is included
    before_action :add_web_search_tool, if: :web_search_enabled?
  end

  # Action that performs web search
  def search_web
    @query = params[:query]
    @search_options = params[:search_options] || {}
    
    # This would be the prompt that triggers web search
    prompt(
      message: "Search the web for: #{@query}",
      tools: [
        {
          type: "web_search_preview",
          search_context_size: @search_options[:context_size] || "medium",
          user_location: @search_options[:location]
        }.compact
      ]
    )
  end

  private

  def add_web_search_tool
    # Merge web search tool into options
    current_tools = @_context.options[:tools] || []
    current_tools << {
      type: "web_search_preview",
      search_context_size: web_search_context_size
    }
    @_context.options[:tools] = current_tools
  end

  def web_search_enabled?
    # Override in including class to control when web search is available
    true
  end

  def web_search_context_size
    # Override in including class to set default context size
    "medium"
  end
end