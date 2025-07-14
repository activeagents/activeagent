json.type :function
json.function do
  json.name action_name
  json.description "This action accepts a 'message' parameter in English and returns its translation in French."
  json.parameters do
    json.type :object
    json.properties do
      json.message do
        json.type :string
        json.description "The text to be translated."
      end
    end
  end
end
