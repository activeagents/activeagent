# AI on Rails with Active Agent
## Rails World 2025 - Lightning Talk (10 minutes)

---

## Slide 1: Title
**[Duration: 15 seconds]**

# AI on Rails with Active Agent
### Making Rails the Best Framework for AI-Powered Apps

Speaker: [Your Name]
Rails World 2025 • Amsterdam

**Speaker Notes:**
- Pause after title
- Make eye contact with audience
- "Rails changed web development 20 years ago. Today, let's talk about how it's perfectly positioned for the AI revolution."

---

## Slide 2: The Bold Claim
**[Duration: 30 seconds | Total: 45s]**

# Rails is the Best Framework for Building AI Apps

*Yes, better than Python frameworks*
*Yes, better than Node.js*
*Yes, I'm serious*

**Speaker Notes:**
- Let this sink in
- "I know this sounds controversial in a world dominated by Python AI libraries..."
- "But hear me out - Rails has something unique to offer"

---

## Slide 3: Why Rails for AI?
**[Duration: 30 seconds | Total: 1:15]**

## Why Rails? Because We've Solved the Hard Parts

- **Convention over Configuration** → Less AI boilerplate
- **ActiveRecord** → Natural data persistence for conversations
- **ActionCable** → Real-time streaming responses built-in
- **ActiveJob** → Background processing for long-running generations
- **Mature ecosystem** → Authentication, deployment, monitoring solved

**Speaker Notes:**
- "While others are building auth systems, we're building AI features"
- "Rails conventions eliminate 80% of the AI integration complexity"

---

## Slide 4: The Problem with Current AI Development
**[Duration: 30 seconds | Total: 1:45]**

## Current AI Development is a Mess

```python
# Every Python AI app reinvents these wheels:
- Session management
- User authentication  
- Background processing
- WebSocket handling
- Database migrations
- API versioning
```

### We spend more time on plumbing than AI

**Speaker Notes:**
- "Look familiar? This is every FastAPI + LangChain project"
- "We're solving solved problems"

---

## Slide 5: Enter Active Agent
**[Duration: 30 seconds | Total: 2:15]**

# Active Agent
## AI Agents as Rails Controllers

```ruby
class SupportAgent < ApplicationAgent
  def answer_question
    @question = params[:question]
    prompt  # It's just a Rails view!
  end
end
```

### Agents inherit from controllers. It's that simple.

**Speaker Notes:**
- "What if AI agents were just... controllers?"
- "What if prompts were just... views?"
- "This is Active Agent"

---

## Slide 6: Convention Over Configuration
**[Duration: 30 seconds | Total: 2:45]**

## Reduce Complexity Through Convention

**Without Active Agent:**
- Configure prompt templates
- Set up message threading
- Wire up tool definitions
- Handle streaming responses
- Manage context windows

**With Active Agent:**
```ruby
rails generate active_agent:agent Support answer_question
```

**Speaker Notes:**
- "One command. Full agent scaffold."
- "Views, tools, tests - all created with Rails conventions"

---

## Slide 7: Prompts are Views
**[Duration: 45 seconds | Total: 3:30]**

## Prompts are Just Action Views

```erb
<%# app/views/support_agent/answer_question.text.erb %>
Customer Question: <%= @question %>

<% if @ticket.present? %>
Ticket #<%= @ticket.id %>
Priority: <%= @ticket.priority %>
<% end %>

Please provide a helpful response.
```

### Use all of Rails' view powers: partials, helpers, layouts

**Speaker Notes:**
- "Your prompt templates use ERB, just like your HTML views"
- "Partials for reusable prompt components"
- "Helpers for formatting"
- "This is the Rails way"

---

## Slide 8: Instructions as Views
**[Duration: 30 seconds | Total: 4:00]**

## System Instructions are Views Too

```erb
<%# app/views/support_agent/instructions.text.erb %>
You are a support agent for <%= Rails.application.name %>.

Current user: <%= current_user.name %>
Time: <%= Time.current %>

Guidelines:
- Be helpful and friendly
- Use available tools when needed
- Respect user privacy
```

**Speaker Notes:**
- "System prompts get the same treatment"
- "Dynamic, contextual, testable"

---

## Slide 9: Messages and Context
**[Duration: 45 seconds | Total: 4:45]**

## Messages Follow Rails Patterns

```ruby
# It's just like handling web requests
generation = SupportAgent.with(
  question: "How do I reset my password?",
  user_id: current_user.id
).answer_question.generate_now

# Messages are like HTTP request/response
response.message.content  # The AI's response
response.requested_actions  # Tools the AI wants to use
```

**Speaker Notes:**
- "Parameters work like Rails params"
- "Responses are objects you can work with"
- "It feels like Rails because it IS Rails"

---

## Slide 10: Tools are Methods
**[Duration: 45 seconds | Total: 5:30]**

## Public Methods Become AI Tools

```ruby
class SupportAgent < ApplicationAgent
  def search_knowledge_base(query:)
    # This becomes a tool the AI can call!
    Article.search(query).limit(5)
  end
  
  def create_ticket(title:, priority:)
    # Another tool, automatically available
    Ticket.create!(
      title: title,
      priority: priority,
      user: current_user
    )
  end
end
```

**Speaker Notes:**
- "Every public method becomes a tool"
- "The AI knows how to use them from your JSON views"
- "No manual tool registration needed"

---

## Slide 11: Model Context Protocol (MCP)
**[Duration: 1 minute | Total: 6:30]**

# Model Context Protocol 📡
## The Future of AI Tool Integration

- **Industry standard** for tool communication
- **Provider agnostic** - Works with any AI model
- **Rails-ready** - Active Agent supports MCP out of the box

```ruby
class ResearchAgent < ApplicationAgent
  def analyze
    prompt(
      mcp_servers: ["postgresql", "github", "slack"]
    )
  end
end
```

### Connect to any data source. No custom code.

**Speaker Notes:**
- "MCP is like OAuth for AI tools"
- "Developed by Anthropic, adopted industry-wide"
- "Your Rails app can talk to any MCP server"
- "Database queries, API calls, file systems - all standardized"

---

## Slide 12: Vector Search Built In
**[Duration: 30 seconds | Total: 7:00]**

## Vector Search with Rails Conventions

```ruby
class Article < ApplicationRecord
  has_neighbors :embedding
  
  def self.semantically_similar(text)
    embedding = generate_embedding(text)
    nearest_neighbors(:embedding, embedding, distance: "cosine")
  end
end

# In your agent:
similar_articles = Article.semantically_similar(@question)
```

**Speaker Notes:**
- "Neighbor gem brings vector search to ActiveRecord"
- "It's just another Rails association"
- "pgvector under the hood"

---

## Slide 13: How Active Agent Uses Rails
**[Duration: 45 seconds | Total: 7:45]**

## Standing on the Shoulders of Giants

- **AbstractController::Base** - Request handling
- **ActionView** - Template rendering  
- **ActiveJob** - Background generation
- **ActionCable** - Streaming responses
- **ActiveRecord** - Conversation persistence

```ruby
class ChatAgent < ApplicationAgent
  # Streaming support built-in
  def chat
    prompt stream: true
  end
end
```

**Speaker Notes:**
- "We're not reinventing Rails, we're extending it"
- "Every Rails feature is available to your agents"
- "Callbacks, filters, concerns - it all works"

---

## Slide 14: How Rails Benefits
**[Duration: 45 seconds | Total: 8:30]**

## Rails Gets Even Better

### Separation of Concerns
- Models: Your business logic
- Controllers: Your web endpoints  
- **Agents: Your AI interactions** ← New layer!
- Views: Your UI (human or AI)

### One App, Multiple Interfaces
```
Web Request → Controller → HTML View
API Request → Controller → JSON View  
AI Request → Agent → Prompt View
```

**Speaker Notes:**
- "Agents are a new layer in the Rails stack"
- "Same conventions, same patterns"
- "Your team already knows how to use this"

---

## Slide 15: Real Production Example
**[Duration: 45 seconds | Total: 9:15]**

## In Production Today

```ruby
# Real code from production Rails app
class ContentModerationAgent < ApplicationAgent
  before_action :load_content
  
  def moderate
    prompt output_schema: :moderation_result
  end
  
  def escalate_to_human(reason:)
    @content.flag_for_review!(reason)
    AdminMailer.content_flagged(@content).deliver_later
  end
end
```

### Processing 10K+ pieces of content daily

**Speaker Notes:**
- "This isn't theory - it's running in production"
- "Same deployment as your Rails app"
- "Same monitoring, same logs, same workflow"

---

## Slide 16: Get Started Today
**[Duration: 30 seconds | Total: 9:45]**

# Start Building AI on Rails

```bash
gem 'activeagent'
rails generate active_agent:install
rails generate active_agent:agent Assistant chat search
```

## activeagent.ai
## github.com/activeagent/activeagent

### Rails is ready for AI. Are you?

**Speaker Notes:**
- "Three commands to AI-powered Rails"
- "Documentation, examples, and community at activeagent.ai"
- [PAUSE]
- "Let's build the future of AI... on Rails"

---

## Slide 17: Thank You
**[Duration: 15 seconds | Total: 10:00]**

# Thank You! 🚂 + 🤖

### Questions? Find me at:
- **Hallway track**
- **@[your_handle]**
- **activeagent.ai/community**

**Speaker Notes:**
- "Thank you Rails World!"
- [Wait for applause]
- [Exit stage]

---

## Backup Slides (if time permits or for Q&A)

---

## Backup: Provider Support
## Works with All Major Providers

- OpenAI (GPT-4, GPT-3.5)
- Anthropic (Claude)
- Ollama (Local models)
- OpenRouter (100+ models)
- Google (Gemini)
- Groq (Fast inference)

```yaml
# config/active_agent.yml
production:
  openai:
    model: gpt-4
  anthropic:
    model: claude-3-opus
```

---

## Backup: Testing Your Agents
## Test Like Any Rails Component

```ruby
class SupportAgentTest < ActiveSupport::TestCase
  test "answers questions accurately" do
    VCR.use_cassette("support_answer") do
      response = SupportAgent.with(
        question: "How do I reset my password?"
      ).answer_question.generate_now
      
      assert response.message.content.include?("password")
    end
  end
end
```

---

## Backup: Performance Metrics

- **Response time**: < 2s for most queries
- **Streaming latency**: < 500ms to first token
- **Memory usage**: Same as typical Rails controller
- **Scalability**: Horizontal scaling with Rails

---

## Speaker Prep Notes

### Key Phrases to Practice:
1. "Rails is the best framework for building AI apps"
2. "Agents are just controllers"
3. "Prompts are just views"
4. "Convention over configuration"
5. "Model Context Protocol"

### Timing Checkpoints:
- 2:00 - Should be introducing Active Agent
- 4:00 - Should be showing prompt examples
- 6:00 - Should be discussing MCP
- 8:00 - Should be on Rails benefits
- 9:00 - Wrapping up with production example

### Energy Points:
- Slide 2: Bold claim - deliver with confidence
- Slide 5: First code example - pause for effect
- Slide 11: MCP - this is your differentiator
- Slide 16: Call to action - build enthusiasm

### Potential Questions to Prepare For:
1. "How does this compare to LangChain?"
2. "What about Python's ML ecosystem?"
3. "Does this work with Rails 7.x?"
4. "How do you handle rate limiting?"
5. "What's the performance overhead?"

### Technical Setup:
- Font size: Minimum 24pt for code
- Syntax highlighting: Ruby, ERB
- Test slides on venue projector if possible
- Have demo app ready on localhost (just in case)

### Remember:
- Speak slowly and clearly
- Make eye contact during key points
- Use gestures for emphasis
- Breathe between sections
- It's okay to pause for effect
- Have fun! You're showing something cool to people who will appreciate it