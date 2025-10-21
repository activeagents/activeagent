module WebSearchable
  extend ActiveSupport::Concern

  # Action that performs web search
  def search_web
    @query = params[:query]
    @search_options = params[:search_options] || {}

    # Build the web search tool configuration
    web_search_tool = {
      type: "web_search_preview",
      search_context_size: @search_options[:context_size] || web_search_context_size
    }

    # Add user location if provided
    if @search_options[:location]
      web_search_tool[:user_location] = @search_options[:location]
    end

    # This would be the prompt that triggers web search
    prompt(
      message: "Search the web for: #{@query}",
      options: {
        use_responses_api: true,
        tools: [ web_search_tool ]
      }
    )
  end

  private

  def web_search_context_size
    # Override in including class to set default context size
    "medium"
  end
end
