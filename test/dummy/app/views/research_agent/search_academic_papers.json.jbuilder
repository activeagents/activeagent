json.type "function"
json.function do
  json.name action_name
  json.description "Search for academic papers on a given topic with optional filters"
  json.parameters do
    json.type "object"
    json.properties do
      json.query do
        json.type "string"
        json.description "The search query for academic papers"
      end
      json.year_from do
        json.type "integer"
        json.description "Start year for publication date filter"
      end
      json.year_to do
        json.type "integer"
        json.description "End year for publication date filter"
      end
      json.field do
        json.type "string"
        json.description "Academic field or discipline"
        json.enum [ "computer_science", "medicine", "physics", "biology", "chemistry", "mathematics", "engineering", "social_sciences" ]
      end
    end
    json.required [ "query" ]
  end
end
