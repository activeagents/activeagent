json.type :function
json.function do
  json.name "search"
  json.description "Search for available flights to a destination"
  json.parameters do
    json.type :object
    json.properties do
      json.departure do
        json.type :string
        json.description "Departure city or airport code"
      end
      json.destination do
        json.type :string
        json.description "Destination city or airport code"
      end
      json.date do
        json.type :string
        json.description "Travel date in YYYY-MM-DD format"
      end
    end
    json.required [ "destination" ]
  end
end
