  # Rails World 2025: Active Agent Examples
## AI on Rails with Structured Outputs, Tools & MCP

### 🎯 Structured Outputs with JSON Schemas

#### Basic Schema Definition
```ruby
class DataExtractionAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"
  
  def extract_invoice
    prompt(
      output_schema: :invoice_schema,
      content_type: :json
    )
  end
end
```

#### Invoice Schema (Jbuilder)
```ruby
# app/views/data_extraction_agent/schemas/invoice_schema.json.jbuilder
json.type "object"
json.properties do
  json.invoice_number { json.type "string" }
  json.date { json.type "string"; json.format "date" }
  json.total do
    json.type "number"
    json.minimum 0
  end
  json.line_items do
    json.type "array"
    json.items do
      json.type "object"
      json.properties do
        json.description { json.type "string" }
        json.quantity { json.type "integer"; json.minimum 1 }
        json.unit_price { json.type "number"; json.minimum 0 }
        json.total { json.type "number"; json.minimum 0 }
      end
      json.required ["description", "quantity", "unit_price", "total"]
    end
  end
  json.vendor do
    json.type "object"
    json.properties do
      json.name { json.type "string" }
      json.address { json.type "string" }
      json.tax_id { json.type "string" }
    end
    json.required ["name"]
  end
end
json.required ["invoice_number", "date", "total", "line_items", "vendor"]
```

#### Usage & Response
```ruby
# Extract structured data from unstructured text
response = DataExtractionAgent.with(
  content: "Invoice #12345 from Acme Corp, dated Jan 15, 2025. 
           5 widgets at $10 each = $50. Total: $50.00"
).extract_invoice.generate_now

# Response is automatically parsed JSON matching the schema
response.message.content
# => {
#   "invoice_number": "12345",
#   "date": "2025-01-15",
#   "total": 50.00,
#   "line_items": [
#     {
#       "description": "widgets",
#       "quantity": 5,
#       "unit_price": 10.00,
#       "total": 50.00
#     }
#   ],
#   "vendor": {
#     "name": "Acme Corp",
#     "address": null,
#     "tax_id": null
#   }
# }
```

### 🗄️ Active Record / Model JSON Schemas

#### Generating Schemas from Models
```ruby
class Product < ApplicationRecord
  # Database columns:
  # - name: string
  # - price: decimal
  # - stock: integer
  # - category: string
  # - active: boolean
  
  validates :name, presence: true
  validates :price, numericality: { greater_than: 0 }
  validates :stock, numericality: { greater_than_or_equal_to: 0 }
  
  # Generate JSON schema from model
  def self.to_json_schema
    {
      type: "object",
      properties: {
        name: { type: "string", minLength: 1 },
        price: { type: "number", minimum: 0 },
        stock: { type: "integer", minimum: 0 },
        category: { 
          type: "string",
          enum: ["electronics", "clothing", "food", "other"]
        },
        active: { type: "boolean" }
      },
      required: ["name", "price", "stock"]
    }
  end
end
```

#### Using Model Schemas in Agents
```ruby
class ProductAgent < ApplicationAgent
  def create_product_listing
    prompt(
      output_schema: Product.to_json_schema,
      content_type: :json
    )
  end
  
  def bulk_import
    prompt(
      output_schema: {
        type: "object",
        properties: {
          products: {
            type: "array",
            items: Product.to_json_schema
          },
          import_summary: {
            type: "object",
            properties: {
              total_count: { type: "integer" },
              categories: { 
                type: "array", 
                items: { type: "string" }
              }
            }
          }
        }
      }
    )
  end
end
```

#### Direct Model Integration
```ruby
# Agent creates valid model instances
response = ProductAgent.with(
  description: "Create a listing for a new laptop"
).create_product_listing.generate_now

# Response content matches model schema
product_data = response.message.content
# => { "name" => "MacBook Pro", "price" => 1999.99, ... }

# Create AR instance directly
product = Product.create!(product_data)
```

### 🛠️ Tools (Agent Actions as Tools)

#### Defining Tools with JSON Views
```ruby
class SupportAgent < ApplicationAgent
  # Each public method becomes a tool
  def search_knowledge_base(query:, limit: 5)
    results = KnowledgeBase.search(query).limit(limit)
    render json: results
  end
  
  def create_ticket(title:, description:, priority: "medium")
    ticket = Ticket.create!(
      title: title,
      description: description,
      priority: priority,
      user: current_user
    )
    render json: ticket
  end
  
  def update_ticket_status(ticket_id:, status:)
    ticket = Ticket.find(ticket_id)
    ticket.update!(status: status)
    render json: { success: true, ticket: ticket }
  end
end
```

#### Tool Schema Definition (Jbuilder)
```ruby
# app/views/support_agent/search_knowledge_base.json.jbuilder
json.type "function"
json.function do
  json.name action_name
  json.description "Search the knowledge base for relevant articles"
  json.parameters do
    json.type "object"
    json.properties do
      json.query do
        json.type "string"
        json.description "Search query"
      end
      json.limit do
        json.type "integer"
        json.description "Maximum results to return"
        json.default 5
      end
    end
    json.required ["query"]
  end
end
```

#### Tool Execution Flow
```ruby
# Agent automatically uses tools when needed
response = SupportAgent.with(
  message: "I can't login to my account"
).respond.generate_now

# Agent might:
# 1. Call search_knowledge_base(query: "login issues")
# 2. Find relevant articles
# 3. If no solution, call create_ticket
# 4. Return consolidated response with ticket number

# Access tool calls made
response.prompt.requested_actions
# => [
#   { name: "search_knowledge_base", arguments: { query: "login issues" } },
#   { name: "create_ticket", arguments: { title: "Login Issue", ... } }
# ]
```

### 🎭 MCP (Model Context Protocol) with Playwright

#### Setting Up MCP Integration
```ruby
class BrowserAgent < ApplicationAgent
  generate_with :anthropic, model: "claude-3-5-sonnet-latest"
  
  def automate_browser
    prompt(
      mcp_servers: ["playwright"],  # Enable MCP server
      actions: mcp_browser_actions  # Include MCP tools
    )
  end
  
  private
  
  def mcp_browser_actions
    [
      :mcp__playwright__browser_navigate,
      :mcp__playwright__browser_click,
      :mcp__playwright__browser_type,
      :mcp__playwright__browser_snapshot,
      :mcp__playwright__browser_take_screenshot
    ]
  end
end
```

#### Real Browser Automation Example
```ruby
class E2ETestAgent < ApplicationAgent
  def test_user_flow
    @test_scenario = params[:scenario]
    @base_url = params[:url]
    
    prompt(
      mcp_servers: ["playwright"],
      message: build_test_instructions
    )
  end
  
  private
  
  def build_test_instructions
    <<~PROMPT
      Test the following user flow on #{@base_url}:
      
      1. Navigate to the homepage
      2. Click "Sign Up" button
      3. Fill in the registration form:
         - Email: test@example.com
         - Password: secure123
         - Name: Test User
      4. Submit the form
      5. Verify successful registration
      6. Take a screenshot of the success page
      
      Use MCP Playwright tools to automate this flow.
      Report any issues found.
    PROMPT
  end
end
```

#### MCP Tool Usage in Response
```ruby
response = E2ETestAgent.with(
  scenario: "user_registration",
  url: "https://myapp.com"
).test_user_flow.generate_now

# Response includes MCP tool calls
response.prompt.requested_actions
# => [
#   { 
#     name: "mcp__playwright__browser_navigate",
#     arguments: { url: "https://myapp.com" }
#   },
#   {
#     name: "mcp__playwright__browser_snapshot",
#     arguments: {}
#   },
#   {
#     name: "mcp__playwright__browser_click",
#     arguments: { 
#       element: "Sign Up button",
#       ref: "button[text='Sign Up']"
#     }
#   },
#   {
#     name: "mcp__playwright__browser_type",
#     arguments: {
#       element: "Email field",
#       ref: "input[name='email']",
#       text: "test@example.com"
#     }
#   },
#   # ... more tool calls
# ]
```

### 🔄 Combining Everything: Full Example

```ruby
class SmartDataAgent < ApplicationAgent
  generate_with :anthropic, model: "claude-3-5-sonnet-latest"
  
  # Structured output with Active Record schema
  def extract_and_save
    @url = params[:url]
    @model_class = params[:model_class]
    
    prompt(
      output_schema: @model_class.to_json_schema,
      mcp_servers: ["playwright"],
      actions: [:save_to_database, :validate_data]
    )
  end
  
  # Tool: Save extracted data
  def save_to_database(data:)
    record = @model_class.create!(data)
    render json: { success: true, id: record.id }
  end
  
  # Tool: Validate before saving
  def validate_data(data:)
    record = @model_class.new(data)
    if record.valid?
      render json: { valid: true }
    else
      render json: { valid: false, errors: record.errors.full_messages }
    end
  end
end
```

#### Usage with MCP Browser Automation
```ruby
# Extract product data from a website and save to database
response = SmartDataAgent.with(
  url: "https://shop.example.com/product/123",
  model_class: Product
).extract_and_save.generate_now

# Agent will:
# 1. Use MCP Playwright to navigate to the URL
# 2. Extract product information from the page
# 3. Structure it according to Product model schema
# 4. Validate the data using validate_data tool
# 5. Save to database using save_to_database tool
# 6. Return structured response

response.message.content
# => {
#   "name": "Wireless Headphones",
#   "price": 129.99,
#   "stock": 50,
#   "category": "electronics",
#   "active": true
# }

# Check what happened
response.prompt.requested_actions
# => [
#   { name: "mcp__playwright__browser_navigate", ... },
#   { name: "mcp__playwright__browser_snapshot", ... },
#   { name: "validate_data", arguments: { data: {...} } },
#   { name: "save_to_database", arguments: { data: {...} } }
# ]
```

### 📊 Advanced: Streaming Structured Outputs

```ruby
class RealtimeAnalysisAgent < ApplicationAgent
  def analyze_stream
    prompt(
      stream: true,
      output_schema: :analysis_schema,
      on_message_chunk: ->(chunk) { broadcast_update(chunk) }
    )
  end
  
  private
  
  def broadcast_update(chunk)
    ActionCable.server.broadcast(
      "analysis_#{params[:session_id]}",
      { partial: chunk }
    )
  end
end
```

  ### 🎉 Key Takeaways

  1. **Structured Outputs** ensure type-safe, validated responses
  2. **Model Schemas** bridge AI and Active Record seamlessly
  3. **Tools** let agents interact with your Rails app naturally
  4. **MCP** enables real browser automation and testing
  5. **Everything is Rails** - familiar patterns, no magic

  ### 🔗 Learn More

  - Documentation: https://docs.activeagents.ai
  - GitHub: https://github.com/activeagents/activeagent
  - Examples: https://docs.activeagents.ai/examples

---

*Rails World 2025 Lightning Talk*
*"AI on Rails: Structured Outputs, Tools & MCP with Active Agent"*