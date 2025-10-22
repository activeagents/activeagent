# Documentation Process Guide

## Overview

This guide documents the ActiveAgent framework's approach to maintaining accurate, tested documentation. All code examples in the documentation are imported from actual test files and agent implementations, ensuring that documented code is always accurate and functional.

## Quick Start for New Contributors

```
Please help me continue improving the ActiveAgent documentation by ensuring all code examples come from tested code using the process documented in this file. The goal is to have deterministic documentation that uses only tested code snippets and includes example outputs from tests. Review this documentation-process.md file and continue where we left off, following the established patterns.
```

## Core Principles

1. **Single Source of Truth**: Code examples come from tested files only
2. **No Hardcoded Examples**: Use VitePress `<<<` import syntax exclusively
3. **Test Everything**: If it's documented, it must be tested
4. **Include Real Outputs**: Use `doc_example_output` helper for response examples
5. **Maintain Determinism**: Use VCR cassettes for consistent API responses

## Process Overview

### 1. Test Helper Method: `doc_example_output`

Location: `test/test_helper.rb`

This helper method captures test output and formats it for documentation inclusion:

**Features:**
- Automatically extracts caller information (file, line number, test name)
- Generates markdown files in `docs/parts/examples/`
- Supports Ruby objects, JSON, and response objects
- Creates deterministic filenames: `{test_file_name}-{test_name}.md`
- Includes metadata with links to source code

**Usage in tests:**
```ruby
def test_example_with_output
  response = MyAgent.with(message: "Hello").my_action.generate_now
  doc_example_output(response) # Creates example file automatically

  # For JSON output:
  json_data = { name: "John", age: 30 }
  doc_example_output(json_data, "custom-name")
end
```

**Generated output includes:**
- Source file reference with clickable link
- Test name for traceability
- Formatted code block (Ruby or JSON)
- Metadata comments for maintainability

### 2. VitePress Import Patterns

ActiveAgent documentation uses VitePress's code import feature to embed code from actual source files.

#### Import Syntax Reference

**Full file import:**
```markdown
<<< @/../test/dummy/app/agents/support_agent.rb {ruby}
```

**Specific line range:**
```markdown
<<< @/../test/dummy/app/agents/support_agent.rb#5-9 {ruby:line-numbers}
```

**Code region (requires region markers in source):**
```markdown
<<< @/../test/agents/support_agent_test.rb#support_agent_tool_call {ruby:line-numbers}
```

#### When to Use Each Pattern

| Pattern | Use Case | Example |
|---------|----------|---------|
| Full file | Complete agent implementations | Agent class files |
| Line range | Specific methods or sections | Configuration blocks |
| Region | Test snippets for documentation | Test examples |

#### Code Region Markers

For test files, add region markers around code you want to reference:

```ruby
# region unique_region_name
def test_example_feature
  agent = MyAgent.new
  response = agent.my_action.generate_now
  assert response.success?
end
# endregion unique_region_name
```

**Region naming convention:**
- Use descriptive, snake_case names
- Make names unique within the file
- Reflect the functionality being demonstrated

### 3. Including Test Outputs in Documentation

**Generate example output in test:**
```ruby
def test_travel_agent_search
  response = TravelAgent.with(destination: "Paris").search.generate_now
  doc_example_output(response) # Generates: travel-agent-test.rb-test-travel-agent-search.md
end
```

**Include in documentation:**
```markdown
::: details Response Example
<!-- @include: @/parts/examples/travel-agent-test.rb-test-travel-agent-search.md -->
:::
```

**Using tabs for multiple output formats:**
```markdown
::: tabs

== Response Object

<!-- @include: @/parts/examples/data-extraction-agent-test.rb-test-parse-chart-content.md -->

== JSON Output

<!-- @include: @/parts/examples/data-extraction-agent-test.rb-parse-chart-json-response.md -->

:::
```

### 4. VCR Cassette Management

ActiveAgent uses VCR to record and replay HTTP interactions with AI providers, ensuring:
- Consistent test results
- No API costs during test runs
- Deterministic documentation examples

**VCR Configuration:**
- Cassettes stored in: `test/fixtures/vcr_cassettes/`
- Cassette names should match test purpose
- Sensitive data filtered automatically via `test_helper.rb`

**Working with VCR:**

```ruby
# In your test file
def test_with_llm_interaction
  VCR.use_cassette("translation_agent_translate") do
    response = TranslationAgent.with(text: "Hello", target: "fr").translate.generate_now
    assert_equal "Bonjour", response.message
  end
end
```

**Best practices:**
- Use descriptive cassette names
- One cassette per distinct API interaction
- Re-record cassettes when API responses change
- Keep cassettes committed in version control
- Ensure `test/dummy/config/master.key` exists for credentials

### 5. Documentation File Structure

#### Test Files with Regions (Selected Examples)
- `test/agents/data_extraction_agent_test.rb` - Multimodal inputs, structured output
- `test/agents/translation_agent_test.rb` - Translation and localization examples
- `test/agents/support_agent_test.rb` - Tool usage and function calling
- `test/agents/streaming_agent_test.rb` - Streaming responses
- `test/agents/browser_agent_test.rb` - Web scraping and browser automation
- `test/generation_provider_examples_test.rb` - Provider configuration examples
- `test/schema_generator_test.rb` - Structured output schema generation

#### Agent Implementations Referenced
- `test/dummy/app/agents/` - All production agent examples
- `test/dummy/app/views/` - Action View templates (optional)

#### Documentation Files
- `docs/docs/getting-started.md` - Onboarding guide
- `docs/docs/framework/active-agent.md` - Core framework documentation
- `docs/docs/framework/provider.md` - Provider architecture
- `docs/docs/action-prompt/actions.md` - Action patterns
- `docs/docs/action-prompt/tools.md` - Tool calling documentation
- `docs/docs/agents/*.md` - Agent-specific guides

#### Generated Example Outputs
- `docs/parts/examples/` - Auto-generated from tests via `doc_example_output`
- Naming: `{test-file-name}-{test-method-name}.md`
- Currently ~70 example files generated

### 6. Documentation Standards and Rules

#### Golden Rules

1. **NO hardcoded code blocks** - All code must come from tested files
2. **Use `<<<` imports exclusively** - Leverage VitePress code import feature
3. **Test everything first** - Write/update tests before documenting
4. **Generate real outputs** - Use `doc_example_output` for examples
5. **Add line numbers** - Use `{ruby:line-numbers}` for test snippets
6. **Descriptive regions** - Name regions clearly for their purpose

#### Code Block Syntax

**Always use:**
```markdown
<<< @/../test/agents/my_agent_test.rb#region_name {ruby:line-numbers}
```

**Never use:**
```markdown
# Hardcoded example - DON'T DO THIS
agent = MyAgent.new
```

#### Best Practices

- **For implementation files**: Import the full file or specific line ranges
- **For test examples**: Use regions to highlight relevant code
- **For outputs**: Generate via `doc_example_output` in tests
- **For complex examples**: Use VitePress tabs to show multiple perspectives
- **For configuration**: Show real configuration from test files

### 9. Troubleshooting

#### Import Not Showing in Documentation

**Problem:** Code import shows as empty or missing

**Solutions:**
1. Verify file path is correct relative to docs root
2. Check region name matches exactly (case-sensitive)
3. Ensure region markers are properly formatted:
   ```ruby
   # region name_here
   # code
   # endregion name_here
   ```
4. Rebuild docs after adding regions: `bin/docs`

#### Example File Not Generated

**Problem:** `doc_example_output` not creating files

**Solutions:**
1. Check test actually ran (verify with `bin/test`)
2. Ensure `docs/parts/examples/` directory exists
3. Verify no filesystem permission issues
4. Check test_helper.rb `doc_example_output` method is loaded

#### VCR Cassette Issues

**Problem:** Tests failing with API errors

**Solutions:**
1. Ensure `test/dummy/config/master.key` exists
2. Check cassette exists in `test/fixtures/vcr_cassettes/`
3. Re-record cassette: `VCR_RECORD_MODE=once bin/test`
4. Verify provider credentials in encrypted credentials

#### Import Path Not Resolving

**Problem:** VitePress can't find imported file

**Solutions:**
1. Use `@/../` prefix for paths relative to docs root
2. Double-check file extension matches
3. Verify line ranges are valid (e.g., `#5-9`)
4. Check VitePress config for path aliases

### 10. Future Improvements

Potential enhancements to the documentation system:

- [ ] Automated detection of hardcoded code blocks in docs
- [ ] CI check to ensure all docs use imports only
- [ ] Better tooling for managing region names
- [ ] Automated regeneration of example outputs
- [ ] Visual diff tool for example output changes
- [ ] Documentation coverage metrics
- [ ] Automated link checking between docs
- [ ] Region name collision detection

### 11. Contributing Guidelines

When adding new documentation:

1. **Start with tests** - Write or identify the test that demonstrates the feature
2. **Add regions** - Wrap relevant test code in descriptive regions
3. **Generate outputs** - Call `doc_example_output` for response examples
4. **Use imports** - Never hardcode examples in markdown
5. **Test locally** - Preview with `bin/docs` before committing
6. **Update this guide** - Document new patterns you establish

When reviewing documentation PRs:

- ✅ All code examples use `<<<` imports
- ✅ No hardcoded code blocks present
- ✅ Tests exist and pass for all examples
- ✅ Example outputs generated and committed
- ✅ VCR cassettes committed (if applicable)
- ✅ Links between docs work correctly
- ✅ Code displays correctly in local preview

## Summary

This documentation process ensures that:

- **Accuracy**: All examples are from tested, working code
- **Maintainability**: Code changes automatically flow to docs
- **Determinism**: VCR cassettes provide consistent outputs
- **Traceability**: Every example links back to source test
- **Quality**: Tests must pass for docs to be valid

By following this process, the ActiveAgent documentation remains a reliable, accurate resource that reflects the actual behavior of the framework.

### 7. Development Workflow

#### 1. Write or Update Tests

```bash
# Create or modify test file with regions
# test/agents/my_agent_test.rb

class MyAgentTest < ActiveSupport::TestCase
  # region my_example_region
  def test_my_feature
    response = MyAgent.with(param: "value").my_action.generate_now
    doc_example_output(response)
    assert response.success?
  end
  # endregion my_example_region
end
```

#### 2. Run Tests to Generate Outputs

```bash
# Run specific test file
bin/test test/agents/my_agent_test.rb

# Run all tests
bin/test

# Run with VCR recording (if updating cassettes)
VCR_RECORD_MODE=once bin/test test/agents/my_agent_test.rb
```

#### 3. Verify Generated Examples

```bash
# Check that example files were created
ls docs/parts/examples/my-agent-test.rb-*.md

# Review the generated content
cat docs/parts/examples/my-agent-test.rb-test-my-feature.md
```

#### 4. Update Documentation

```markdown
<!-- docs/docs/framework/my-feature.md -->

## Example Usage

<<< @/../test/agents/my_agent_test.rb#my_example_region {ruby:line-numbers}

::: details Response
<!-- @include: @/parts/examples/my-agent-test.rb-test-my-feature.md -->
:::
```

#### 5. Preview Documentation Locally

```bash
# Start VitePress dev server
bin/docs

# Or directly with npm
cd docs && npm run docs:dev
```

#### 6. Verify Links and Imports

- Open http://localhost:5173 in browser
- Navigate to updated documentation pages
- Verify code imports render correctly
- Check that examples display properly
- Test internal links between pages

### 8. Common Documentation Patterns

#### Pattern 1: Simple Code Example

For straightforward examples, import a region from a test:

```markdown
## Basic Usage

<<< @/../test/agents/application_agent_test.rb#basic_usage {ruby:line-numbers}
```

#### Pattern 2: Implementation + View

Show agent implementation with its optional view template:

```markdown
::: code-group
<<< @/../test/dummy/app/agents/translation_agent.rb {ruby:line-numbers}
<<< @/../test/dummy/app/views/translation_agent/translate.json.jbuilder {ruby:line-numbers}
<<< @/../test/dummy/app/views/translation_agent/translate.text.erb {erb:line-numbers}
:::
```

#### Pattern 3: Test Example with Output

Show test code and its actual output:

```markdown
## Example Test

<<< @/../test/agents/data_extraction_agent_test.rb#extract_data_example {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/data-extraction-agent-test.rb-test-extract-data.md -->
:::
```

#### Pattern 4: Multiple Output Formats (Tabs)

Show different perspectives of the same result:

```markdown
::: tabs

== Response Object

<!-- @include: @/parts/examples/agent-test.rb-test-structured-output.md -->

== JSON Output

<!-- @include: @/parts/examples/agent-test.rb-json-output.md -->

== Schema

<!-- @include: @/parts/examples/agent-test.rb-output-schema.md -->

:::
```

#### Pattern 5: Configuration Examples

Show real configuration from test setup:

```markdown
## Provider Configuration

<<< @/../test/generation_provider_examples_test.rb#openai_configuration {ruby:line-numbers}
```

#### Pattern 6: Full Agent Implementation

Import complete agent file for reference:

```markdown
## Complete Example

<<< @/../test/dummy/app/agents/support_agent.rb {ruby}
```
