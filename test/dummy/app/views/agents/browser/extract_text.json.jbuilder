  json.name action_name
  json.description "Extract text content from the page or a specific element"
  json.parameters do
    json.type "object"
    json.properties do
      json.selector do
        json.type "string"
        json.description "CSS selector for the element to extract text from (default: body)"
      end
    end
  end
