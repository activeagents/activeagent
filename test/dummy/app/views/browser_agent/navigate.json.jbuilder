json.name action_name
json.description "Navigate to a URL in the browser"
json.parameters do
  json.type "object"
  json.properties do
    json.url do
      json.type "string"
      json.description "The URL to navigate to"
    end
  end
  json.required [ "url" ]
end
