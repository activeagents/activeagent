  json.name action_name
  json.description "Follow a link on the current page"
  json.parameters do
    json.type "object"
    json.properties do
      json.text do
        json.type "string"
        json.description "Text of the link to follow"
      end
      json.href do
        json.type "string"
        json.description "Partial href to match and follow"
      end
    end
  end
