json.name action_name
json.description "Multiply two numbers"
json.parameters do
  json.type "object"
  json.properties do
    json.a do
      json.type "number"
      json.description "First number"
    end
    json.b do
      json.type "number"
      json.description "Second number"
    end
  end
  json.required [ "a", "b" ]
end
