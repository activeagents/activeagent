json.type :function
json.function do
  json.name action_name
  json.description "Analyzes a document and returns insights about its content, structure, and key information."
  json.parameters do
    json.type :object
    json.properties do
      json.text do
        json.type :string
        json.description "The document text to analyze."
      end
      json.analysis_type do
        json.type :string
        json.enum [ "summary", "key_points", "sentiment", "full" ]
        json.description "The type of analysis to perform on the document."
      end
      json.use_structured_output do
        json.type :boolean
        json.description "Whether to return structured analysis results."
        json.default false
      end
    end
    json.required [ "text" ]
  end
end
