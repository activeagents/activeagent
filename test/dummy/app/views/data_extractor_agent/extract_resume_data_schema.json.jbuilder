json.type "object"
json.properties do
  json.personal_info do
    json.type "object"
    json.properties do
      json.name do
        json.type "string"
      end
      json.title do
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
  end
  json.experience do
    json.type "array"
    json.items do
      json.type "object"
      json.properties do
        json.company do
          json.type "string"
        end
        json.position do
          json.type "string"
        end
        json.duration do
          json.type "string"
        end
        json.achievements do
          json.type "array"
          json.items do
            json.type "string"
          end
        end
      end
      json.required [ "company", "position" ]
    end
  end
  json.education do
    json.type "object"
    json.properties do
      json.degree do
        json.type "string"
      end
      json.institution do
        json.type "string"
      end
      json.duration do
        json.type "string"
      end
      json.gpa do
        json.type "string"
      end
    end
  end
  json.skills do
    json.type "object"
    json.properties do
      json.programming_languages do
        json.type "array"
        json.items do
          json.type "string"
        end
      end
      json.frameworks do
        json.type "array"
        json.items do
          json.type "string"
        end
      end
      json.databases do
        json.type "array"
        json.items do
          json.type "string"
        end
      end
      json.tools do
        json.type "array"
        json.items do
          json.type "string"
        end
      end
    end
  end
end
json.required [ "personal_info" ]
