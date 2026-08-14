---
title: Tools, Streaming & Caching
description: Declarative tool schemas from JSON templates or an inline DSL, live tool status over ActionCable, and a cache that replays identical tool calls instead of repeating the side effect.
---
# {{ $frontmatter.title }}

ActiveAgent passes [tools](/actions/tools) to `prompt` as schema hashes and
routes the model's calls to methods of the same name. SolidAgent adds three
things around that: somewhere to keep the schemas, a way to tell the user
what's happening while a tool runs, and a cache so identical calls don't
pay twice.

## Declaring tool schemas

`SolidAgent::HasTools` gives you two places to put a schema — a JSON view
template, or an inline DSL — and one method, `tools`, that returns all of
them.

```ruby
class BrowserAgent < ApplicationAgent
  include SolidAgent::HasTools

  has_tools :fetch_url            # app/views/browser_agent/tools/fetch_url.json.erb

  tool :summarize_page do
    description "Summarize text that was already fetched"
    parameter :text, type: :string, required: true, description: "Page text to summarize"
    parameter :sentences, type: :integer, default: 3
  end

  def browse
    prompt tools: tools
  end

  def fetch_url(url:)      = Net::HTTP.get(URI(url))
  def summarize_page(text:, sentences: 3) = { summary: text.split(". ").first(sentences).join(". ") }
end
```

### From view templates

`has_tools :fetch_url` renders
`app/views/browser_agent/tools/fetch_url.json.erb` — the agent's
underscored class name, then `tools/` — and parses the result as JSON.
Being a template, it can use ERB: enum values from the database, a
description that changes per environment.

```erb
{
  "type": "function",
  "name": "fetch_url",
  "description": "Fetch a web page and return its text",
  "parameters": {
    "type": "object",
    "properties": {
      "url": { "type": "string", "description": "Absolute http(s) URL to fetch" }
    },
    "required": ["url"]
  }
}
```

`has_tools` with no arguments discovers every template in the directory
instead of listing them.

### Inline

The `tool` DSL builds the same OpenAI-shaped hash in Ruby:

```ruby
tool :search do
  description "Search for documents"
  parameter :query, type: :string, required: true
  parameter :format, type: :string, enum: %w[json xml csv]
  parameter :tags, type: :array, items: { type: :string }
  parameter :limit, type: :integer, default: 10
end
```

`parameter` takes `type:`, `required:`, `description:`, `enum:`, `items:`,
`properties:` and `default:`.

### Getting the schemas out

`tools` returns templates first, then inline definitions, and memoizes.
Editing a template with the server running? `reload_tools!` drops the
cache.

The tool name must match a method on the agent, and tool methods take
keyword arguments — that part is the framework's contract, not SolidAgent's.

## Live tool status

A tool that takes eight seconds looks identical to a hung request. Include
`SolidAgent::StreamsToolUpdates` and declare a description, and each call
announces itself before it runs:

```ruby
class BrowserAgent < ApplicationAgent
  include SolidAgent::HasTools
  include SolidAgent::StreamsToolUpdates

  has_tools :fetch_url, :summarize_page

  tool_description :fetch_url, ->(args) { "Fetching #{args[:url]}..." }
  tool_description :summarize_page, "Summarizing the page..."
end
```

Declaring a description is what wraps the method — tools without one still
run, they just stay quiet. A `Proc` receives the call's arguments; a
`String` is used as-is. Common tool names (`navigate`, `search`,
`extract_text`, `read_file`, …) have sensible defaults.

Broadcasting is opt-in per generation: it happens only when
`params[:stream_id]` is present, so the same agent runs silently from a job
or the console.

```ruby
stream_id = "tool_status:#{current_user.id}:#{SecureRandom.uuid}"

BrowserAgent.with(stream_id: stream_id, message: "Summarize rubyonrails.org")
  .browse.generate_now
```

Each call broadcasts to that stream name:

```ruby
{ tool_status: { name: "fetch_url",
                 description: "Fetching https://rubyonrails.org...",
                 timestamp: "2026-08-14T12:00:00Z" } }
```

The client half is an ordinary channel. Scope the stream id to the current
user, or one subscriber can listen in on another's run:

```ruby
class ToolStatusChannel < ApplicationCable::Channel
  def subscribed
    stream_id = params[:stream_id].to_s
    reject unless stream_id.start_with?("tool_status:#{current_user.id}:")

    stream_from stream_id
  end
end
```

This is tool-level progress, separate from token-level
[response streaming](/agents/streaming) — most UIs want both.

## Caching tool results

`SolidAgent::ToolCache` replays a result instead of repeating the side
effect:

```ruby
def fetch_url(url:)
  SolidAgent::ToolCache.fetch(tool: "fetch_url", args: { url: url }, ttl: 5.minutes) do
    response = Net::HTTP.get_response(URI(url))

    response.is_a?(Net::HTTPSuccess) ? { body: response.body } : { error: "HTTP #{response.code}" }
  end
end
```

- Keys are `(tool, normalized args)` — argument order and symbol vs string
  keys don't change the key.
- Replays come back tagged `cached: true`, so both you and the model can
  tell a replay from a fresh call.
- **Error-shaped results are never cached.** A hash with an `:error` key
  passes through, so a transient failure doesn't stick for the whole TTL.

Configure it globally:

```ruby
SolidAgent::ToolCache.default_ttl = 60
SolidAgent::ToolCache.store = ActiveSupport::Cache::MemoryStore.new  # Rails.cache by default
SolidAgent::ToolCache.enabled = false                               # e.g. in tests
```

The same call from a different agent, job or MCP server hits the same
entry — the key is the tool and its arguments, not the caller.

## Generators

```bash
# A JSON tool template plus the method stub to paste in
rails generate solid_agent:tool search ResearchAgent --parameters query:string:required limit:integer

# The inline DSL version, printed rather than written
rails generate solid_agent:tool search ResearchAgent --inline

# An agent with the tool concerns already included
rails generate solid_agent:agent Browser --tools --streaming
```

## See also

- [Tools](/actions/tools) — the framework's tool calling, which these schemas feed
- [MCPs](/actions/mcps) — remote tool servers, cacheable the same way
- [Streaming](/agents/streaming) — token-level streaming of the response itself
- [Examples](/solid_agent/examples#tools-live-status-and-caching) — the worked example
