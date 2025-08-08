json.name action_name
json.description "Subtract one number from another"
json.parameters do
  json.type "object"
  json.properties do
    json.a do
      json.type "number"
      json.description "Number to subtract from"
    end
    json.b do
      json.type "number"
      json.description "Number to subtract"
    end
  end
  json.required ["a", "b"]
end