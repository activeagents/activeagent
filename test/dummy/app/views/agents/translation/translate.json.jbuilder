json.type :function
json.function do
  json.name action_name
  json.description "This action takes params locale and message and returns a translated message."
  json.parameters do
    json.type :object
    json.properties do
      json.locale do
        json.type :string
        json.description "The target language for translation."
      end
      json.message do
        json.type :string
        json.description "The text to be translated."
      end
    end
  end
end
