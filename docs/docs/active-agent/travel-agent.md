```json [app/views/agents/travel_agent/search.json.erb]
{
  "tool": {
    "name": "search",
    "description": "Search for travel options",
    "parameters": {
      "type": "object",
      "properties": {
        "location": {
          "type": "string",
          "description": "The location to search for travel options"
        }
      },
      "required": ["location"]
    }
  }
}
```

```erb [app/views/agents/travel_agent/search.html.erb]
<h1>Search for Travel Options</h1>
<p>Enter the location you want to search for:</p>
<form action="<%= search_path %>" method="post">
  <input type="text" name="location" placeholder="Enter location" required>
  <button type="submit">Search</button>
</form> 
```
:::
This code snippet defines the `TravelAgent` class with three actions: `search`, `book`, and `confirm`. Each action can be implemented with specific logic to handle travel-related queries. The `prompt` method is used to render the action's content in the prompt context.


## Basic Usage
When interfacing with an agent, you typically start by providing a prompt context to the agent. This context can include instructions, user messages, and any other relevant information that the agent needs to generate a response. The agent will then process this context and return a response based on its defined actions.

```ruby
TravelAgent.with(
  instructions: "Help users with travel-related queries, using the search, book, and confirm actions.",
  messages: [
    { role: 'user', content: 'I need a hotel in Paris' }
  ]
).prompt_context.generate_later
```
This code snippet initializes the `TravelAgent` with a set of instructions and a user message. The agent will then process this context and generate a response based on its defined actions. -->
