json.name action_name
json.description "Calculate the area of a rectangle"
json.parameters do
  json.type "object"
  json.properties do
    json.width do
      json.type "number"
      json.description "Width of the rectangle"
    end
    json.height do
      json.type "number"
      json.description "Height of the rectangle"
    end
  end
  json.required ["width", "height"]
end