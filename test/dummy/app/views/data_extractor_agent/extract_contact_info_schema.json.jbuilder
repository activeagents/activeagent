json.type "object"
json.properties do
  json.name do
    json.type "string"
  end
  json.email do
    json.type "string"
  end
  json.phone do
    json.type "string"
  end
  json.location do
    json.type "string"
  end
end
json.required [ "name" ]
