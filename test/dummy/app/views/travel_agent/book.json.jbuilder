json.type :function
json.function do
  json.name action_name
  json.description "Book a specific flight"
  json.parameters do
    json.type :object
    json.properties do
      json.params do
        json.type :object
        json.properties do
          json.flight_id do
            json.type :string
            json.description "The flight identifier to book"
          end
          json.passenger_name do
            json.type :string
            json.description "Name of the passenger"
          end
          json.passenger_email do
            json.type :string
            json.description "Email address for booking confirmation"
          end
        end
        json.required [ "flight_id", "passenger_name" ]
      end
    end
    json.required [ "params" ]
  end
end
