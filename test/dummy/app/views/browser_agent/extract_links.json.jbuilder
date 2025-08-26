  json.name action_name
  json.description "Extract links from the current page"
  json.parameters do
    json.type "object"
    json.properties do
      json.selector do
        json.type "string"
        json.description "CSS selector to extract links from (default: body)"
      end
      json.limit do
        json.type "integer"
        json.description "Maximum number of links to extract (default: 10)"
      end
    end
  end

