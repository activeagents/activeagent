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
    end
  end

