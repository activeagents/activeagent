json.name action_name
json.description "Click on an element in the page"
json.parameters do
  json.type "object"
  json.properties do
    json.selector do
      json.type "string"
      json.description "CSS selector for the element to click"
    end
    json.text do
      json.type "string"
      json.description "Text of the link or button to click (alternative to selector)"
    end
  end
end