json.type :function
json.function do
  json.name action_name
  json.description "Get the current weather for a location"
  json.parameters do
    json.type :object
    json.properties do
      json.location do
        json.type :string
        json.description "The city and state, e.g. San Francisco, CA"
      end
      json.unit do
        json.type :string
        json.enum ["celsius", "fahrenheit"]
        json.description "The temperature unit"
      end
    end
    json.required ["location"]
  end
end
