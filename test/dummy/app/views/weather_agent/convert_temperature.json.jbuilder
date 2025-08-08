json.name action_name
json.description "Convert temperature between Celsius and Fahrenheit"
json.parameters do
  json.type "object"
  json.properties do
    json.value do
      json.type "number"
      json.description "Temperature value to convert"
    end
    json.from do
      json.type "string"
      json.description "Unit to convert from (celsius or fahrenheit)"
      json.enum ["celsius", "fahrenheit"]
    end
    json.to do
      json.type "string"
      json.description "Unit to convert to (celsius or fahrenheit)"
      json.enum ["celsius", "fahrenheit"]
    end
  end
  json.required ["value", "from", "to"]
end