  json.name action_name
  json.description "Fill in a form field"
  json.parameters do
    json.type "object"
    json.properties do
      json.field do
        json.type "string"
        json.description "Name or label of the field to fill"
      end
      json.value do
        json.type "string"
        json.description "Value to fill in the field"
      end
      json.selector do
        json.type "string"
        json.description "CSS selector for the field (alternative to field name)"
      end
    end
    json.required [ "value" ]
  end
