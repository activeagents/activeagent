json.type "object"
json.additionalProperties false
json.properties do
  json.technical_skills do
    json.type "array"
    json.items do
      json.type "string"
    end
  end
  json.soft_skills do
    json.type "array"
    json.items do
      json.type "string"
    end
  end
  json.certifications do
    json.type "array"
    json.items do
      json.type "string"
    end
  end
end
json.required [ "technical_skills", "soft_skills", "certifications" ]
