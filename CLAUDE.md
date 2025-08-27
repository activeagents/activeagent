# CLAUDE.md - Understanding ActiveAgent Repository

## Overview

ActiveAgent is a Ruby on Rails framework that brings AI-powered capabilities to Rails applications using familiar Rails patterns. It treats AI agents as controllers with enhanced generation capabilities, memory, and tooling. Unlike traditional web controllers that handle HTTP requests, agents handle AI generation requests while maintaining the same familiar Rails patterns and conventions.

### Core Concepts

1. **Agents are Controllers** - Agents inherit from `ActiveAgent::Base` and follow Rails controller patterns
2. **Actions are Tools** - Public methods in agents become tools that can interact with systems and code
3. **Prompts use Action View** - Leverages Rails' view system for rendering prompts and responses
4. **Generation Providers** - Common interface for AI providers (OpenAI, Anthropic, Ollama, etc.)

## How ActiveAgent Works

ActiveAgent bridges Rails conventions with AI capabilities through a carefully designed architecture that feels natural to Rails developers.

### Architecture Overview

The framework follows a layered architecture:

```
Your Rails App
└── ApplicationAgent (your base agent)
    └── ActiveAgent::Base (framework base)
        └── ActiveAgent::ActionPrompt::Base (prompt handling)
            └── AbstractController::Base (Rails foundation)
```

### Understanding Messages and Actions

#### Messages: The Core Communication Structure
Messages are the fundamental way agents communicate. Each message has:
- **Role**: `:system`, `:user`, `:assistant`, or `:tool`
- **Content**: The rendered view content
- **Requested Actions**: Tool calls the agent wants to make

#### Message Types and Their Purpose:

1. **System Messages (`:system`)** - Instructions to the agent
   - Rendered from `instructions.text.erb` views
   - Provide context and behavioral guidance
   - Can include dynamic ERB content

2. **User Messages (`:user`)** - Input from users
   - Action views render these messages
   - Not just plain text - can be any format (text, HTML, JSON)

3. **Assistant Messages (`:assistant`)** - Agent responses
   - What the AI generates in response
   - Can include requested tool calls

4. **Tool Messages (`:tool`)** - Results from executed actions
   - System's response to agent-requested tool calls
   - Contains the output of the action execution

### The `with` Method Pattern

The `with` method is a **class method** that allows you to pass parameters to agents before calling actions. This follows the Rails pattern and returns a `Generation` object that can be executed.

#### Important: `with` is a CLASS Method

```ruby
# CORRECT - with is called on the class
response = MyAgent.with(param: value).my_action.generate_now

# INCORRECT - with is NOT an instance method  
agent = MyAgent.new
response = agent.with(param: value).my_action  # This will error!
```

#### How it Works

1. `with` returns a `Parameterized::Agent` object
2. Calling an action on it returns a `Generation` object
3. Call `generate_now` or `generate_later` to execute

```ruby
# Step by step
generation = TranslationAgent.with(message: "Hello", locale: "es").translate
# generation is now a Generation object
response = generation.generate_now  # Execute the generation

# Or chain it all together
response = TranslationAgent.with(message: "Hello", locale: "es").translate.generate_now
```

### Actions: The Bridge Between Rails and AI

Actions in ActiveAgent serve multiple purposes:

#### 1. **As Message Templates**
Actions render views that become messages in the conversation:

```ruby
class TranslationAgent < ApplicationAgent
  def translate
    @message = params[:message]
    @locale = params[:locale]
    
    prompt  # Renders translate.text.erb as a user message
  end
end
```

The `translate.text.erb` view:
```erb
translate: <%= params[:message] %>; to <%= params[:locale] %>
```

#### 2. **As Tool Definitions**
JSON views define tool schemas for the AI:

```erb
# translate.json.jbuilder
json.type "function"
json.function do
  json.name action_name
  json.description "Translates text to specified locale"
  json.parameters do
    json.type "object"
    json.properties do
      json.message do
        json.type "string"
        json.description "Text to translate"
      end
      json.locale do
        json.type "string"
        json.description "Target locale"
      end
    end
    json.required ["message", "locale"]
  end
end
```

#### 3. **As Executable Tools**
Public methods become tools the AI can call:
- Method executes when AI requests the tool
- Results are rendered back as tool messages
- Can perform any Rails operation (database, API calls, etc.)

### The Generation Flow

```
1. User Input → Creates initial context
2. Action Method → Renders view as message
3. Prompt Context → Combines messages, instructions, available tools
4. AI Generation → Produces response with potential tool calls
5. Tool Execution → Runs requested actions
6. Tool Results → Rendered as tool messages
7. Reiteration → Continues until no more tool calls
```

### The Prompt Method

The `prompt` method is the heart of message rendering:

```ruby
prompt(
  content_type: :text,      # Format of the view
  message: "content",       # Direct content (optional)
  messages: [],             # Additional context messages
  template_name: "custom",  # Override default template
  instructions: {           # System message configuration
    template: "special"     # Or direct string
  },
  actions: [],              # Available tools (defaults to all public methods)
  output_schema: :schema    # For structured output
)
```

## Repository Structure

```
activeagent/
├── lib/active_agent/        # Core framework code
│   ├── base.rb              # Base agent class
│   ├── generation.rb        # Generation logic
│   ├── action_prompt/       # Prompt system components
│   └── generation_provider/ # AI provider adapters
├── test/                    # Test suite with examples
│   ├── dummy/               # Rails test app
│   └── agents/              # Agent test examples
├── docs/                    # VitePress documentation
│   ├── docs/                # Markdown documentation files
│   └── parts/examples/      # Generated example outputs
└── bin/                     # Executable scripts
```

## Documentation Process

This repository follows a strict documentation process to ensure all code examples are tested and accurate:

### Key Principles

1. **No hardcoded code blocks** - All code must come from tested files
2. **Use `<<<` imports only** - Import code from actual tested implementation and test files
3. **Test everything** - If it's in docs, it must have a test
4. **Include outputs** - Use `doc_example_output` for response examples

### Import Patterns

#### Implementation Files
```markdown
<<< @/../test/dummy/app/agents/support_agent.rb {ruby}
<<< @/../test/dummy/app/agents/support_agent.rb#5-9 {ruby:line-numbers}
```

#### Test Code with Regions

##### In test file:
```ruby
# region unique_region_name
code_to_include
# endregion unique_region_name
```
##### In docs:
```markdown
<<< @/../test/agents/support_agent_test.rb#unique_region_name {ruby:line-numbers}
```

#### Test Output Examples
```markdown
::: details Response Example
<!-- @include: @/parts/examples/test-name-test-name.md -->
:::
```

### The `doc_example_output` Method

Located in `test/test_helper.rb`, this method:
- Captures test output and formats it for documentation
- Generates files in `docs/parts/examples/` with deterministic names
- Supports Ruby objects, JSON, and response objects
- Includes metadata (source file, line number, test name)

Usage in tests:
```ruby
response = agent.generate(prompt)
doc_example_output(response)  # Generates example file
```

## Working with Documentation

### Current Branch Status
The `data-extraction-example-docs` branch is improving documentation found on docs.activeagents.ai. All code snippets should include example outputs using the `doc_example_output` method.

### Documentation Files Needing Review

Files that may still have hardcoded examples:
- `docs/docs/framework/generation-provider.md`
- `docs/docs/framework/active-agent.md`
- `docs/docs/action-prompt/actions.md`
- `docs/docs/action-prompt/messages.md`
- `docs/docs/action-prompt/prompts.md`

### Running Tests and Building Docs

1. Run tests to generate examples:
```bash
# Run all tests
bin/test

# Run specific test file
bin/test test/agents/your_agent_test.rb

# Run specific test by name pattern
bin/test test/agents/your_agent_test.rb -n "test_name_pattern"
```

2. Build and serve docs locally:
```bash
# Start development server (recommended)
bin/docs  # Starts vitepress dev server at http://localhost:5173

# Build static docs (for production)
cd docs && npm run docs:build

# Preview built docs
cd docs && npm run docs:preview
```

## Key Framework Components

### Agents
- Inherit from `ActiveAgent::Base`
- Use `generate_with` to specify AI provider
- Define actions as public instance methods
- Support callbacks (`before_action`, `after_generation`)

### Actions
- Render prompts using `prompt` method
- Support multiple content types (text, JSON, HTML)
- Can accept parameters via `with` method
- Include tool schemas in JSON views

### Generation Providers
- OpenAI, Anthropic, Ollama, OpenRouter supported
- Configured in `config/active_agent.yml`
- Support streaming, callbacks, and queued generation

### Prompts
- Built using Action View templates
- Support instructions (default, custom template, or plain text)
- Include message history and available actions
- Can be multimodal (text, images, files)

## Rails Integration

ActiveAgent integrates seamlessly with Rails applications as a complementary system to your existing controllers and models.

### Installation

1. **Add to Gemfile**:
```ruby
gem 'activeagent'
```

2. **Run installation generator**:
```bash
rails generate active_agent:install
```
This creates:
- `app/agents/application_agent.rb` - Base agent class
- `config/active_agent.yml` - Configuration file

3. **Configure API credentials**:
```bash
rails credentials:edit
```
Add your API keys:
```yaml
openai:
  api_key: your_openai_key
anthropic:
  api_key: your_anthropic_key
```

### How Agents Work in Rails

#### 1. **Direct Usage Pattern**
Call agents directly from controllers, models, or jobs:

```ruby
class MessagesController < ApplicationController
  def create
    agent = SupportAgent.new
    response = agent.generate(prompt: params[:message])
    
    render json: { 
      reply: response.message.content,
      actions_taken: response.prompt.requested_actions
    }
  end
end
```

#### 2. **Action-Based Generation**
Use specific actions to generate with templated prompts:

```ruby
# app/agents/translation_agent.rb
class TranslationAgent < ApplicationAgent
  def translate
    @text = params[:message]
    @target = params[:locale]
    prompt  # Renders translate.text.erb
  end
end

# app/views/translation_agent/translate.text.erb
Translate: <%= @text %>
To: <%= @target %>

# Usage in controller - Note: `with` is a CLASS method
# It returns a Generation object that can be executed
response = TranslationAgent.with(message: "Hello", locale: "es").translate.generate_now

# Alternative: store the generation for later execution
generation = TranslationAgent.with(message: "Hello", locale: "es").translate
response = generation.generate_now  # Execute when ready
```

#### 3. **Background Generation**
Process long-running AI tasks asynchronously:

```ruby
class DataAnalysisAgent < ApplicationAgent
  self.queue_adapter = :sidekiq
  
  def analyze_dataset
    @data = params[:dataset]
    prompt content_type: :json
  end
end

# In your controller
generation = DataAnalysisAgent.with(dataset: large_data).generate_later

# Check status later
generation.finished? # => true/false
generation.response  # => AI response when ready
```

### View Templates and Message Rendering

ActiveAgent uses Rails' view system to render all message types:

#### Directory Structure
```
app/views/
├── layouts/
│   └── agent.text.erb              # Optional shared layout
├── application_agent/
│   └── instructions.text.erb       # Default system instructions
└── support_agent/
    ├── instructions.text.erb       # Agent-specific system message
    ├── answer_question.text.erb    # Action view (user message)
    ├── answer_question.json.jbuilder # Tool schema definition
    └── _shared_context.text.erb    # Reusable partial
```

#### System Instructions (System Messages)
```erb
<%# app/views/support_agent/instructions.text.erb %>
You are a helpful support agent for <%= Rails.application.name %>.

Current user: <%= @user&.name || "Guest" %>
Time: <%= Time.current %>

Available tools:
<% controller.action_schemas.each do |schema| %>
- <%= schema["function"]["name"] %>: <%= schema["function"]["description"] %>
<% end %>

Guidelines:
- Be friendly and professional
- Use tools when needed to help users
- Provide accurate information
```

#### Action Views (User/Tool Messages)
```erb
<%# app/views/support_agent/answer_question.text.erb %>
Customer Question: <%= @question %>

<% if @ticket.present? %>
Ticket #<%= @ticket.id %>
Priority: <%= @ticket.priority %>
Previous interactions: <%= @ticket.messages.count %>
<% end %>

<% if @knowledge_base_results.any? %>
Relevant KB articles:
<% @knowledge_base_results.each do |article| %>
- <%= article.title %>: <%= article.summary %>
<% end %>
<% end %>
```

#### Tool Schemas (JSON)
```ruby
# app/views/support_agent/answer_question.json.jbuilder
json.type "function"
json.function do
  json.name action_name
  json.description "Answer customer support questions"
  json.parameters do
    json.type "object"
    json.properties do
      json.question do
        json.type "string"
        json.description "The customer's question"
      end
      json.ticket_id do
        json.type "integer"
        json.description "Optional ticket ID for context"
      end
    end
    json.required ["question"]
  end
end
```

### Integration Patterns

#### 1. **Service Objects**
Encapsulate complex agent workflows:

```ruby
class CustomerSupportService
  def initialize(user)
    @user = user
    @agent = SupportAgent.new
  end
  
  def handle_message(content, ticket = nil)
    # Build conversation context
    messages = ticket ? build_history(ticket) : []
    
    # Generate response with context
    response = @agent.generate(
      prompt: content,
      messages: messages,
      context: { user_id: @user.id, ticket_id: ticket&.id }
    )
    
    # Process any tool calls
    if response.requested_actions.any?
      process_tool_calls(response.requested_actions)
    end
    
    response
  end
  
  private
  
  def build_history(ticket)
    ticket.messages.map do |msg|
      ActiveAgent::Message.new(
        role: msg.from_agent? ? :assistant : :user,
        content: msg.content
      )
    end
  end
end
```

#### 2. **Model Integration**
Add AI capabilities to ActiveRecord models:

```ruby
class Article < ApplicationRecord
  def generate_summary
    ContentAgent.with(
      title: title,
      content: content,
      max_length: 200
    ).summarize.generate_now
  end
  
  def translate_to(locale)
    TranslationAgent.with(
      message: content,
      locale: locale
    ).translate.generate_now
  end
end
```

#### 3. **Controller Helpers**
Create reusable agent helpers:

```ruby
# app/controllers/concerns/agent_helpers.rb
module AgentHelpers
  extend ActiveSupport::Concern
  
  included do
    helper_method :chat_agent
  end
  
  private
  
  def chat_agent
    @chat_agent ||= ChatAgent.new.with(
      user_id: current_user&.id,
      session_id: session.id
    )
  end
  
  def generate_with_agent(agent_class, action, params = {})
    agent_class.with(params).public_send(action).generate_now
  end
end
```

### Configuration

#### Environment-Specific Settings
```yaml
# config/active_agent.yml
default: &default
  logger: <%= Rails.logger %>
  
development:
  <<: *default
  openai:
    access_token: <%= Rails.application.credentials.dig(:openai, :api_key) %>
    model: gpt-4o
    temperature: 0.7
    
production:
  <<: *default
  openai:
    access_token: <%= Rails.application.credentials.dig(:openai, :api_key) %>
    model: gpt-4o
    temperature: 0.3
  anthropic:
    access_token: <%= Rails.application.credentials.dig(:anthropic, :api_key) %>
    model: claude-3-5-sonnet-latest
```

#### Runtime Configuration
Override settings at runtime:

```ruby
# Change provider for specific agent
class PremiumAgent < ApplicationAgent
  generate_with :anthropic, model: "claude-3-opus-latest"
end

# Override per-generation
agent.generate(
  prompt: "Complex task",
  options: {
    model: "gpt-4-turbo",
    temperature: 0.9
  }
)
```

## Creating Your First Agent

Let's build a simple blog writing agent to understand how ActiveAgent works.

### Step 1: Generate the Agent

```bash
rails generate active_agent:agent BlogWriter write_post edit_post
```

This creates:
- `app/agents/blog_writer_agent.rb`
- `app/views/blog_writer_agent/` directory
- `test/agents/blog_writer_agent_test.rb`

### Step 2: Define the Agent

```ruby
# app/agents/blog_writer_agent.rb
class BlogWriterAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"
  
  before_action :set_blog_context
  
  def write_post
    @topic = params[:topic]
    @style = params[:style] || "professional"
    @length = params[:length] || 500
    
    prompt
  end
  
  def edit_post
    @content = params[:content]
    @instructions = params[:instructions]
    
    prompt
  end
  
  private
  
  def set_blog_context
    @blog_name = "My Rails Blog"
    @author = current_user&.name || "Guest Author"
  end
end
```

### Step 3: Create View Templates

#### System Instructions
```erb
<%# app/views/blog_writer_agent/instructions.text.erb %>
You are a professional blog writer for <%= @blog_name %>.
Author: <%= @author %>

Your writing should be:
- Engaging and informative
- SEO-friendly with appropriate keywords
- Structured with clear headings
- Factually accurate

Available tools:
<% controller.action_schemas.each do |schema| %>
- <%= schema["function"]["name"] %>: <%= schema["function"]["description"] %>
<% end %>
```

#### Action Views (User Messages)
```erb
<%# app/views/blog_writer_agent/write_post.text.erb %>
Write a blog post about: <%= @topic %>

Requirements:
- Style: <%= @style %>
- Target length: <%= @length %> words
- Include an engaging introduction
- Add relevant subheadings
- Conclude with a call-to-action

Please create an original, well-structured blog post.
```

```erb
<%# app/views/blog_writer_agent/edit_post.text.erb %>
Please edit the following blog post:

---
<%= @content %>
---

Editing instructions: <%= @instructions %>

Maintain the original tone and style while making the requested changes.
```

#### Tool Schemas
```ruby
# app/views/blog_writer_agent/write_post.json.jbuilder
json.type "function"
json.function do
  json.name action_name
  json.description "Write a new blog post on a given topic"
  json.parameters do
    json.type "object"
    json.properties do
      json.topic do
        json.type "string"
        json.description "The topic to write about"
      end
      json.style do
        json.type "string"
        json.enum ["professional", "casual", "technical", "creative"]
        json.description "Writing style"
      end
      json.length do
        json.type "integer"
        json.description "Target word count"
      end
    end
    json.required ["topic"]
  end
end
```

### Step 4: Use the Agent

#### In a Controller
```ruby
class BlogPostsController < ApplicationController
  def new
    @post = BlogPost.new
  end
  
  def generate
    # Generate a blog post
    response = BlogWriterAgent.with(
      topic: params[:topic],
      style: params[:style],
      length: params[:length]
    ).write_post.generate_now
    
    @generated_content = response.message.content
    @post = BlogPost.new(
      title: extract_title(@generated_content),
      content: @generated_content,
      author: current_user
    )
    
    render :new
  end
  
  def edit_with_ai
    @post = BlogPost.find(params[:id])
    
    response = BlogWriterAgent.with(
      content: @post.content,
      instructions: params[:instructions]
    ).edit_post.generate_now
    
    @post.content = response.message.content
    render :edit
  end
  
  private
  
  def extract_title(content)
    # Extract first H1 or first line as title
    content.match(/^#\s+(.+)$/)&.captures&.first || 
    content.lines.first.strip
  end
end
```

#### As a Service
```ruby
class BlogGenerationService
  def initialize(user)
    @user = user
  end
  
  def generate_weekly_posts(topics)
    topics.map do |topic|
      response = BlogWriterAgent.with(
        topic: topic,
        style: "professional",
        length: 800
      ).write_post.generate_now
      
      BlogPost.create!(
        title: extract_title(response.message.content),
        content: response.message.content,
        author: @user,
        status: "draft"
      )
    end
  end
  
  def improve_seo(post)
    response = BlogWriterAgent.with(
      content: post.content,
      instructions: "Improve SEO by adding relevant keywords, meta description, and improving headings"
    ).edit_post.generate_now
    
    post.update!(content: response.message.content)
  end
end
```

### Step 5: Test Your Agent

```ruby
# test/agents/blog_writer_agent_test.rb
require "test_helper"

class BlogWriterAgentTest < ActiveSupport::TestCase
  setup do
    @agent = BlogWriterAgent.new
  end
  
  test "writes blog post about Rails" do
    VCR.use_cassette("blog_writer_rails_post") do
      response = BlogWriterAgent.with(
        topic: "Getting Started with Rails 7",
        style: "technical",
        length: 600
      ).write_post.generate_now
      
      assert response.message.content.include?("Rails")
      assert response.message.content.length > 400
      
      # Generate documentation example
      doc_example_output(response)
    end
  end
  
  test "edits post for clarity" do
    original = "Rails is framework. It make web app easy."
    
    VCR.use_cassette("blog_writer_edit_grammar") do
      response = BlogWriterAgent.with(
        content: original,
        instructions: "Fix grammar and improve clarity"
      ).edit_post.generate_now
      
      assert response.message.content != original
      assert response.message.content.include?("Rails")
    end
  end
end
```

### Key Takeaways

1. **Agents are like controllers** - They use familiar Rails patterns
2. **Actions render views** - Each action has associated view templates
3. **Views become messages** - Templates are rendered as conversation messages
4. **JSON views define tools** - The AI knows what tools are available
5. **Use `with` for parameters** - Pass data like Rails params
6. **Test with VCR** - Record API responses for consistent tests

## Testing Conventions

### VCR Cassettes
- Used for recording API responses
- Keep existing cassettes committed
- Create unique names for new tests
- Ensure `test/dummy/config/master.key` is present

### Test Organization
- Agent tests in `test/agents/`
- Framework tests in respective directories
- Use regions for important test snippets
- Always call `doc_example_output` for examples

## Important Commands

```bash
# Install dependencies
bundle install

# Run all tests
bin/test

# Run specific test file
bin/test test/agents/specific_agent_test.rb

# Run specific test by name
bin/test test/agents/specific_agent_test.rb -n "test_name_pattern"

# Start documentation development server
bin/docs  # http://localhost:5173

# Build documentation for production
cd docs && npm run docs:build

# Generate new agent
rails generate active_agent:agent AgentName action1 action2
```

## Configuration

### active_agent.yml
```yaml
development:
  openai:
    access_token: <%= Rails.application.credentials.dig(:openai, :api_key) %>
    model: gpt-4o
  anthropic:
    access_token: <%= Rails.application.credentials.dig(:anthropic, :api_key) %>
    model: claude-3-5-sonnet-latest
```

### Credentials
Store API keys in Rails credentials:
```bash
rails credentials:edit
```

## Advanced Patterns

### Multi-Agent Workflows

Chain multiple agents together for complex tasks:

```ruby
class DocumentProcessingService
  def process_document(file_path)
    # Extract content
    extracted_data = DataExtractionAgent.with(
      file_path: file_path,
      schema: :document_schema
    ).extract.generate_now
    
    # Summarize content
    summarizer = SummaryAgent.new
    summary = summarizer.with(
      content: extracted_data.content,
      max_length: 200
    ).summarize
    
    # Translate if needed
    if needs_translation?(extracted_data)
      translator = TranslationAgent.new
      translated = translator.with(
        message: summary.content,
        locale: current_locale
      ).translate
      summary = translated
    end
    
    # Store results
    ProcessedDocument.create!(
      original_path: file_path,
      extracted_data: extracted_data.content,
      summary: summary.content,
      language: detected_language(extracted_data)
    )
  end
end
```

### Conversation Context Management

Build rich conversation histories:

```ruby
class ConversationAgent < ApplicationAgent
  def respond
    @message = params[:message]
    @conversation_id = params[:conversation_id]
    
    # Load conversation history
    @messages = load_conversation_history
    
    prompt(
      messages: @messages,  # Provide full context
      instructions: { template: "conversational" }
    )
  end
  
  private
  
  def load_conversation_history
    Conversation.find(@conversation_id).messages.map do |msg|
      ActiveAgent::Message.new(
        role: msg.role.to_sym,
        content: msg.content,
        requested_actions: msg.tool_calls
      )
    end
  end
end
```

### Dynamic Tool Selection

Conditionally include tools based on context:

```ruby
class AdaptiveAgent < ApplicationAgent
  def assist
    @query = params[:query]
    @user = current_user
    
    # Dynamically select available actions
    available_actions = determine_available_actions
    
    prompt(
      actions: available_actions,
      instructions: build_contextual_instructions
    )
  end
  
  private
  
  def determine_available_actions
    actions = [:search, :calculate]
    
    # Add user-specific actions
    if @user.admin?
      actions += [:modify_system, :access_logs]
    end
    
    if @query.match?(/weather|temperature/)
      actions << :get_weather
    end
    
    actions
  end
  
  def build_contextual_instructions
    base_instructions = "You are a helpful assistant."
    
    if @user.preferences[:technical]
      base_instructions += " Provide technical details when relevant."
    end
    
    base_instructions
  end
end
```

### Streaming Responses

Handle real-time streaming for better UX:

```ruby
class StreamingChatController < ApplicationController
  include ActionController::Live
  
  def stream
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    
    agent = ChatAgent.new
    
    agent.on_message_chunk do |chunk|
      response.stream.write("data: #{chunk.to_json}\n\n")
    end
    
    agent.generate(
      prompt: params[:message],
      stream: true
    )
  ensure
    response.stream.close
  end
end
```

### Structured Output with Schemas

Ensure consistent response formats:

```ruby
class DataAgent < ApplicationAgent
  def analyze_sales
    @data = params[:sales_data]
    
    prompt(
      content_type: :json,
      output_schema: :sales_analysis
    )
  end
end

# app/views/data_agent/schemas/sales_analysis.json.jbuilder
json.type "object"
json.properties do
  json.summary do
    json.type "string"
    json.description "Executive summary"
  end
  json.metrics do
    json.type "object"
    json.properties do
      json.total_revenue { json.type "number" }
      json.growth_rate { json.type "number" }
      json.top_products do
        json.type "array"
        json.items { json.type "string" }
      end
    end
  end
  json.recommendations do
    json.type "array"
    json.items do
      json.type "object"
      json.properties do
        json.action { json.type "string" }
        json.priority { json.enum ["high", "medium", "low"] }
        json.impact { json.type "string" }
      end
    end
  end
end
json.required ["summary", "metrics", "recommendations"]
```

### Error Handling and Retries

Build resilient agent interactions:

```ruby
class ResilientAgent < ApplicationAgent
  generate_with :openai, 
    model: "gpt-4o",
    max_retries: 3,
    retry_on: [OpenAI::RateLimitError]
  
  def process
    @data = params[:data]
    
    begin
      prompt
    rescue ActiveAgent::GenerationError => e
      # Log error
      Rails.logger.error "Generation failed: #{e.message}"
      
      # Fallback to simpler model
      self.class.generate_with :openai, model: "gpt-3.5-turbo"
      retry
    end
  end
end
```

### Testing Complex Interactions

Test multi-step agent workflows:

```ruby
class ComplexAgentTest < ActiveSupport::TestCase
  test "multi-agent document processing" do
    VCR.use_cassette("complex_document_flow") do
      # Step 1: Extract data
      extracted = DataExtractionAgent.with(
        content: file_fixture("report.pdf").read
      ).extract.generate_now
      
      assert extracted.message.content.present?
      
      # Step 2: Analyze with context
      analyzer = AnalysisAgent.new
      analysis = analyzer.generate(
        prompt: "Analyze this data",
        messages: [
          ActiveAgent::Message.new(
            role: :user,
            content: "Focus on financial metrics"
          ),
          ActiveAgent::Message.new(
            role: :tool,
            content: extracted.content
          )
        ]
      )
      
      assert analysis.requested_actions.any?
      
      # Step 3: Execute requested actions
      analysis.requested_actions.each do |action|
        result = analyzer.public_send(
          action.name,
          **action.params.symbolize_keys
        )
        assert result.success?
      end
      
      doc_example_output(analysis)
    end
  end
end
```

### Performance Optimization

Cache expensive operations:

```ruby
class CachedAgent < ApplicationAgent
  def analyze_trends
    @timeframe = params[:timeframe]
    
    # Cache analysis results
    Rails.cache.fetch(cache_key, expires_in: 1.hour) do
      prompt
    end
  end
  
  private
  
  def cache_key
    "agent_analysis/#{self.class.name}/#{@timeframe}/#{cache_version}"
  end
  
  def cache_version
    # Invalidate cache when data changes
    DataPoint.maximum(:updated_at).to_i
  end
end
```

## Best Practices

1. **Always test code examples** - Never add untested code to docs
2. **Use regions in tests** - Makes it easy to import specific snippets
3. **Include example outputs** - Users need to see what to expect
4. **Follow Rails conventions** - ActiveAgent extends Rails patterns
5. **Document tool schemas** - JSON views should clearly define tool structure
6. **Handle errors gracefully** - Plan for API failures and rate limits
7. **Cache when appropriate** - Reduce API calls for repeated queries
8. **Stream for better UX** - Use streaming for long-running generations
9. **Version your prompts** - Track prompt changes like code changes
10. **Monitor usage** - Track API costs and performance metrics

## Next Steps for Documentation

When updating documentation:
1. Find hardcoded examples in markdown files
2. Create or update tests with proper regions
3. Add `doc_example_output` calls to generate examples
4. Replace hardcoded blocks with `<<<` imports
5. Add `@include` directives for example outputs
6. Run tests and verify documentation builds correctly

## Importent things to remember
- when adding new paramters ensure the prompt and merge params method in @lib/active_agent/base.rb allows them to be passed through
- Use vscode regions for snippets of examples in docs
- We use Agent classes by loading params `.with` that returns a Parameterized Agent class then calling actions on the parameterized agent like `ApplicationAgent.with(message:'hi').prompt_context` this creates the ActiveAgent Generation object that we can then run `generate_now` or `generate_later` on
- 1. The Generation is a lazy wrapper - It doesn't create the actual agent or context until needed (see line 56-58 in processed_agent method)
  2. It delegates to the context - The __getobj__ method (line 14) returns @context ||= processed_agent.context, which means it delegates all method calls to the underlying context object
  3. The context comes from the processed agent - When you call generate_now, it:
    - Creates a new agent instance (@agent_class.new)
    - Calls agent.process(@action, *@args) to set up the agent with the action and arguments
    - Runs callbacks and performs the generation
    - Returns the context which contains the prompt and response

  So in our test, when we do:
  generation = ResearchAgent.with(topic: "Ruby performance").comprehensive_research

  We get a Generation object that:
  - Knows the agent class (ResearchAgent)
  - Knows the action (:comprehensive_research)
  - Has the args from with(topic: "Ruby performance")
  - But hasn't actually created the agent or context yet

  Only when we call generation.generate_now does it:
  1. Create the agent instance
  2. Process the action with the parameters
  3. Execute the generation
  4. Return the context with the actual prompt and response

  This lazy evaluation pattern allows for queueing generations with generate_later for background processing, which is why the Generation class has that safety check (lines 62-70) to prevent accessing the context before enqueueing.

- VCR cassettes need to be removed and tests run again to record new cassettes when the request params change

- Do not hardcode examples and make sure to use vscode regions and vite-press code snippets imports

- use `bin/rubocop -a` to autofix linting issues