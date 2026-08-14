---
title: Agent Manifests
description: Define agents in portable .agent.md files — frontmatter for model, tools and schemas, Markdown for instructions — then validate, convert and build classes from them.
---
# {{ $frontmatter.title }}

An agent's interesting part is usually prose: the instructions, the tool
descriptions, the shape of what it should return. `SolidAgent::AgentManifest`
lets that live in a file rather than a class — reviewable in a pull
request, diffable, and portable to frameworks that aren't Rails.

```markdown
---
name: changelog-writer
version: 1.0.0
description: Turns a range of merged pull requests into a release changelog
model: anthropic/claude-sonnet-4-20250514
config:
  temperature: 0.3

input:
  schema:
    repository: "string, The repository the release belongs to"
    audience?: "string(users, operators, contributors), Who it is written for"

tools:
  - name: list_merged_pulls
    description: List pull requests merged between two refs
    inputSchema:
      type: object
      properties:
        repository: { type: string }
      required: [repository]

activeagent:
  class_name: ChangelogWriterAgent
  concerns:
    - has_tools: [list_merged_pulls]
---

# Changelog Writer

You write release changelogs from merged pull requests.

## Instructions

1. Call `list_merged_pulls` for the requested range.
2. Group the changes into Added, Changed, Fixed and Removed.
3. Write one line per change, in the present tense.
```

YAML frontmatter for the structured half, Markdown for the instructions.
The full field list is in the
[`.agent.md` specification](https://github.com/activeagents/solid_agent/blob/main/docs/agent-md-spec.md).

## Formats it reads

| Format | File | Notes |
|--------|------|-------|
| `.agent.md` | `*.agent.md` | Native; the only one with no lossy fields |
| Dotprompt | `*.prompt` | Google's format |
| CrewAI | `agents.yaml` | Multi-agent definitions |
| GitHub Copilot | `*.prompt.md` | Copilot prompt files |

```ruby
SolidAgent::AgentManifest.parser_formats    # what can be read
SolidAgent::AgentManifest.exporter_formats  # what can be written
```

## Loading

`load` takes whatever you have — a path, a URL, a JSON or YAML string, or a
Hash — and detects the format:

```ruby
manifest = SolidAgent::AgentManifest.load("config/agents/changelog_writer.agent.md")
manifest = SolidAgent::AgentManifest.load("https://example.com/agents/support.agent.md")
manifest = SolidAgent::AgentManifest.load({ name: "quick", model: "openai/gpt-4o-mini" })

manifest.name          # => "changelog-writer"
manifest.model         # => "anthropic/claude-sonnet-4-20250514"
manifest.instructions  # the Markdown body
manifest.tools.map(&:name)
manifest.fingerprint   # stable digest — the version an agent ran under
```

`parse` and `parse_string` are the explicit forms when you already know the
format.

## Validating

```ruby
SolidAgent::AgentManifest.validate(path)   # => [] when valid, else error strings
SolidAgent::AgentManifest.valid?(path)     # => true / false
SolidAgent::AgentManifest.validate!(path)  # raises ValidationError
SolidAgent::AgentManifest.validate(path, strict: true)
```

Validation covers names, model identifiers, tool definitions, schemas,
resources and framework extensions. Worth a test, so a broken manifest
fails the build rather than a request:

```ruby
test "every shipped manifest is valid" do
  Dir["config/agents/**/*.agent.md"].each do |path|
    assert_empty SolidAgent::AgentManifest.validate(path), path
  end
end
```

## Building an agent from one

```ruby
klass = SolidAgent::AgentManifest.load_agent(path, class_name: "ChangelogWriterAgent")

klass._manifest_provider      # => "anthropic"
klass._manifest_model         # => "claude-sonnet-4-20250514"
klass._manifest_instructions  # the Markdown body
klass._manifest               # the Manifest, fingerprint included
klass.new.tools.map { |t| t[:name] }
```

The class arrives configured but not finished. It inherits from
`ApplicationAgent`, includes the concerns the `activeagent:` section asked
for, and carries the manifest's tool schemas and metadata — but behaviour
is still Ruby. Supply the actions and the tool bodies:

```ruby
class ChangelogWriterAgent
  generate_with _manifest_provider.to_sym, model: _manifest_model

  def write
    prompt instructions: _manifest_instructions, message: params[:message], tools: tools
  end

  # Declared tools raise NotImplementedError until you define them.
  def list_merged_pulls(repository:, from: nil, to: nil)
    GitHub.merged_pulls(repository, from: from, to: to)
  end
end
```

`activeagent.class_name` in the frontmatter names the constant, so
`class_name:` is only needed to override it. Name it either way when the
agent persists context — contexts are keyed by class name, and an anonymous
class has none.

## Converting

```ruby
SolidAgent::AgentManifest.export(manifest, :dotprompt)
SolidAgent::AgentManifest.export_to_file(manifest, :agent_md, "config/agents/support.agent.md")
SolidAgent::AgentManifest.convert("agents.yaml", :agent_md)  # CrewAI in, .agent.md out
```

Formats don't overlap perfectly — `.agent.md` carries fields the others
have nowhere to put — so round-tripping through a lossier format loses
them. Convert on the way in, keep `.agent.md` as the source of truth.

## Provenance

```ruby
SolidAgent::AgentManifest.provenance(manifest)
SolidAgent::AgentManifest.checksum(content)
```

An agent built from a manifest reports `manifest_fingerprint` in the
[provenance](/solid_agent/context#provenance-and-trace-correlation)
recorded on every generation — so a stored conversation says which version
of a manifest produced it.

## Generator

```bash
rails generate solid_agent:manifest research
rails generate solid_agent:manifest research --template research --tools search_web fetch_url
rails generate solid_agent:manifest support --context user --format dotprompt
```

Presets: `research`, `assistant`, `reviewer`, `chat`.

## See also

- [`.agent.md` specification](https://github.com/activeagents/solid_agent/blob/main/docs/agent-md-spec.md)
- [Instructions](/agents/instructions) — the framework's own instruction templates
- [Examples](/solid_agent/examples#manifests) — the worked example
