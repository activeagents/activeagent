module ActiveAgent
  class Operation < AbstractController::Base
    include AbstractController::Rendering
    include ActionView::Rendering  # Allows rendering of ERB templates without a view context tied to a request
    append_view_path "app/views"  # Ensure the controller knows where to look for view templates

    def process_tool(tool_name, params)
      send(tool_name, params)  # Dynamically calls the method corresponding to tool_name
    rescue NoMethodError
      "Tool not found: #{tool_name}"
    end
  end
end
