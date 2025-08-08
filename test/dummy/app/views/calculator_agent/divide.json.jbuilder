json.name action_name
json.description "Divide one number by another"
json.parameters do
  json.type "object"
  json.properties do
    json.a do
      json.type "number"
      json.description "Dividend (number to be divided)"
    end
    json.b do
      json.type "number"
      json.description "Divisor (number to divide by)"
    end
  end
  json.required ["a", "b"]
end