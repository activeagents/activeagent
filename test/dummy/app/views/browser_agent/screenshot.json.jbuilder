  json.name action_name
  json.description "Take a screenshot of the current page"
  json.parameters do
    json.type "object"
    json.properties do
      json.filename do
        json.type "string"
        json.description "Name for the screenshot file"
      end
      json.full_page do
        json.type "boolean"
        json.description "Whether to capture the full page (true) or just viewport (false)"
      end
      json.main_content_only do
        json.type "boolean"
        json.description "Automatically detect and crop to main content area, excluding headers (default: true)"
      end
      json.selector do
        json.type "string"
        json.description "CSS selector for a specific element to screenshot (optional)"
      end
      json.area do
        json.type "object"
        json.description "Specific area of the page to capture (optional)"
        json.properties do
          json.x do
            json.type "integer"
            json.description "X coordinate of the top-left corner"
          end
          json.y do
            json.type "integer"
            json.description "Y coordinate of the top-left corner"
          end
          json.width do
            json.type "integer"
            json.description "Width of the area to capture"
          end
          json.height do
            json.type "integer"
            json.description "Height of the area to capture"
          end
        end
      end
    end
  end

