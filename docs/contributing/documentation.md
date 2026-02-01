---
title: Documentation
description: Deterministic, always-accurate documentation where every code example comes from tested files. Learn how to maintain documentation that can't drift from code.
---
# {{ $frontmatter.title }}

ActiveAgent documentation is deterministic and always accurate because every code example comes from tested files. Documentation and code can't drift apart—if the code changes, the docs automatically reflect it.

**Important:** When updating ActiveAgent documentation, you must follow the process outlined in this file. All code examples must be imported from tested files using VitePress imports—never hardcode examples in markdown.

## Why This Matters

**The problem with typical docs:** Code examples get hardcoded, tests don't cover them, and they become outdated as the codebase evolves.

**Our solution:** Import all code directly from tests and implementations using VitePress. Examples stay synchronized with the actual codebase, outputs are real, and everything is traceable.

## Core Principles

1. **Zero hardcoded examples** — Use VitePress `<<<` imports only
2. **Test everything documented** — If it's in docs, it must be tested
3. **Generate real outputs** — Use `doc_example_output` for response examples
4. **Maintain determinism** — VCR cassettes ensure consistent API responses

## Quick Start

To document a new feature:

1. Write tests with region markers around example code
2. Run tests to generate example outputs
3. Import test regions into documentation
4. Preview locally with `bin/docs`

## Running Tests

### Prerequisites

Install dependencies:

```bash
bundle install
```

### Running the Test Suite

```bash
bin/test
```

This uses `gemfiles/rails8.gemfile` by default. To test against other Rails versions:

```bash
BUNDLE_GEMFILE=gemfiles/rails7.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails7.gemfile bin/test
```

See `gemfiles/` for available configurations.

### API Keys

Most tests use VCR cassettes (recorded HTTP responses), so they run without API credentials. You only need API keys when:

- Re-recording VCR cassettes
- Running tests against live APIs
- Adding tests for new API interactions

To set API keys, create `.env.test` in the project root:

```bash
OPENAI_API_KEY=your_key_here
ANTHROPIC_API_KEY=your_key_here
OPEN_ROUTER_API_KEY=your_key_here
```

Or export them in your shell before running tests.

## How It Works

### VitePress Code Imports

Import code directly from source files instead of copying:

```markdown
<!-- Import full file -->
<<< @/../test/dummy/app/agents/support_agent.rb {ruby}

<!-- Import region (recommended for tests) -->
<<< @/../test/docs/support_agent_test.rb#tool_call_example {ruby:line-numbers}
```

**When to use each:**
- Full file: Complete agent implementations
- Region: Test code examples (preferred)

### Code Regions in Tests

Mark code you want to reference in documentation:

```ruby
# region tool_call_example
def test_tool_calling
  response = SupportAgent.with(question: "Reset my password").help.generate_now
  doc_example_output(response)
  assert_includes response.tool_calls.map(&:name), "reset_password"
end
# endregion tool_call_example
```

**Region naming:** Use descriptive `snake_case` names unique within the file.

### Generating Example Outputs

The `doc_example_output` helper (in `test/test_helper.rb`) captures test results for documentation:

```ruby
def test_data_extraction
  response = DataAgent.with(content: "...").extract.generate_now
  doc_example_output(response) # Generates markdown file automatically
  assert response.success?
end
```

**What it creates:**
- File: `docs/parts/examples/{test-file}-{test-name}.md`
- Contains: Formatted output with source file link and metadata
- Supports: Ruby objects, JSON, and response objects

**Include in docs:**
```markdown
::: details Response Example
<!-- @include: @/parts/examples/data-agent-test.rb-test-data-extraction.md -->
:::
```

### VCR for Deterministic API Responses

VCR records and replays HTTP interactions, ensuring:
- Consistent test results across runs
- No API costs during development
- Deterministic documentation examples

```ruby
def test_translation
  VCR.use_cassette("translation_agent_translate") do
    response = TranslationAgent.with(text: "Hello", target: "fr").translate.generate_now
    assert_equal "Bonjour", response.message
  end
end
```

Cassettes stored in `test/fixtures/vcr_cassettes/`. Re-record with: `VCR_RECORD_MODE=once bin/test`

## Workflow

### 1. Write Tests with Regions

```ruby
# test/docs/my_agent_test.rb
class MyAgentTest < ActiveSupport::TestCase
  # region basic_usage
  def test_basic_feature
    response = MyAgent.with(param: "value").my_action.generate_now
    doc_example_output(response)
    assert response.success?
  end
  # endregion basic_usage
end
```

### 2. Run Tests

```bash
# Run specific test
bin/test test/docs/my_agent_test.rb

# Re-record VCR cassettes if needed
VCR_RECORD_MODE=once bin/test test/docs/my_agent_test.rb
```

### 3. Import into Documentation

```markdown
<!-- docs/examples/my-feature.md -->

## Basic Usage

<<< @/../test/docs/my_agent_test.rb#basic_usage {ruby:line-numbers}

::: details Response
<!-- @include: @/parts/examples/my-agent-test.rb-test-basic-feature.md -->
:::
```

### 4. Preview

```bash
bin/docs  # Starts VitePress dev server at http://localhost:5173
```

Verify code imports render correctly and links work.

## Common Patterns

### Simple Example

Import a test region to show basic usage:

```markdown
<<< @/../test/docs/application_agent_test.rb#basic_usage {ruby:line-numbers}
```

### Implementation + View

Show multiple related files together:

```markdown
::: code-group
```ruby [translation_agent.rb]
class TranslationAgent < ApplicationAgent
  def translate
    prompt
  end
end
\```
```ruby [translate.json.jbuilder]
json.action_name "translate"
json.message params[:message]
\```
:::
```

### Test with Output

Display test code alongside its actual result:

```markdown
\```ruby
prompt = DataExtractionAgent.with(
  image_path: image_path
).parse_content

response = prompt.generate_now
\```

::: details Response
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-test-extract-data.md -->
:::
```

### Multiple Output Formats

Use tabs to show different perspectives of the same data:

```markdown
::: tabs

== Response Object
<!-- @include: @/parts/examples/agent-test.rb-test-structured-output.md -->

== JSON
<!-- @include: @/parts/examples/agent-test.rb-json-output.md -->

:::
```

## File Structure

**Source implementations:**
- `test/dummy/app/agents/` — Agent classes
- `test/dummy/app/views/` — Action View templates
- `test/docs/` - Test files

**Documentation:**
- `docs/` — All documentation markdown files
- `docs/parts/examples/` — Auto-generated outputs (naming: `{test-file}-{test-method}.md`)

## Troubleshooting

### Import Not Showing

- Verify file path (use `@/../` prefix)
- Check region name matches exactly (case-sensitive)
- Ensure region markers formatted correctly: `# region name` / `# endregion name`
- Rebuild: `bin/docs`

### Example File Not Generated

- Confirm test ran: `bin/test`
- Check `docs/parts/examples/` exists
- Verify `doc_example_output` is called in test

### VCR Issues

- Ensure `test/dummy/config/master.key` exists
- Re-record cassette: `VCR_RECORD_MODE=once bin/test`
- Check cassette exists in `test/fixtures/vcr_cassettes/`

### Import Path Not Resolving

- Use `@/../` prefix for paths relative to docs root
- Verify file extension correct
- Check line ranges valid (e.g., `#5-9`)

## Rules

**Always:**
- ✅ Import all code with `<<<` syntax
- ✅ Test code before documenting
- ✅ Use regions for test examples
- ✅ Generate outputs with `doc_example_output`
- ✅ Add line numbers: `{ruby:line-numbers}`
- ✅ Preview locally before committing

**Never:**
- ❌ Hardcode examples in markdown
- ❌ Document untested features
- ❌ Copy/paste code from tests
- ❌ Break existing imports when refactoring

## Contributing

**When adding documentation:**

1. Write or identify the test demonstrating the feature
2. Add descriptive region markers around example code
3. Call `doc_example_output` for response examples
4. Import regions into documentation
5. Preview with `bin/docs`
6. Commit generated examples and VCR cassettes

**When reviewing documentation PRs:**

- ✅ All examples use `<<<` imports
- ✅ Tests exist and pass
- ✅ Example outputs generated and committed
- ✅ VCR cassettes committed (if applicable)
- ✅ Code renders correctly in preview
- ✅ Links work
