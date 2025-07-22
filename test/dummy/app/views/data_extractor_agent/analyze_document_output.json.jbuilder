json.type "object"
json.properties do
  json.summary do
    json.type "string"
    json.description "A concise summary of the document content"
  end
  json.key_topics do
    json.type "array"
    json.items do
      json.type "string"
    end
    json.description "Main topics or themes identified in the document"
  end
  json.sentiment do
    json.type "object"
    json.properties do
      json.overall do
        json.type "string"
        json.enum ["positive", "negative", "neutral"]
      end
      json.confidence do
        json.type "number"
        json.minimum 0
        json.maximum 1
      end
    end
    json.required ["overall", "confidence"]
  end
  json.document_type do
    json.type "string"
    json.enum ["resume", "article", "report", "email", "legal", "technical", "other"]
    json.description "The identified type of document"
  end
  json.key_entities do
    json.type "array"
    json.items do
      json.type "object"
      json.properties do
        json.entity do
          json.type "string"
        end
        json.type do
          json.type "string"
          json.enum ["person", "organization", "location", "date", "skill", "other"]
        end
      end
      json.required ["entity", "type"]
    end
  end
  json.readability_score do
    json.type "number"
    json.minimum 0
    json.maximum 100
    json.description "Estimated readability score (0-100, higher is more readable)"
  end
end
json.required ["summary", "key_topics", "sentiment", "document_type"]
