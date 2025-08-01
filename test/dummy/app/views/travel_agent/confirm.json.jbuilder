json.type :function
json.function do
  json.name action_name
  json.description "Confirm a flight booking"
  json.parameters do
    json.type :object
    json.properties do
      json.confirmation_number do
        json.type :string
        json.description "The booking confirmation number"
      end
      json.send_email do
        json.type :boolean
        json.description "Whether to send confirmation email"
      end
    end
    json.required [ "confirmation_number" ]
  end
end
