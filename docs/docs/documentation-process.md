# Documentation Process Guide

## Prompt for New Session

```
Please help me continue improving the ActiveAgent documentation by ensuring all code examples come from tested code using the process documented in this file. The goal is to have deterministic documentation that uses only tested code snippets and includes example outputs from tests. Review this documentation-process.md file and continue where we left off, following the established patterns.
```

## Process Overview

### 1. Enhanced Test Helper Method

We created an enhanced `doc_example_output` method in `test/test_helper.rb` that:
- Captures test output and formats it for documentation
- Includes metadata (source file, line number, test name)
- Supports both Ruby objects and JSON formatting
- Generates files in `docs/parts/examples/` with deterministic names

```ruby
def doc_example_output(example = nil, test_name = nil)
  # Extracts caller info and formats output with metadata
  # Outputs to: docs/parts/examples/{file_name}-{test_name}.md
end
```

### 2. Documentation Patterns

#### For Implementation Files (app/agents/*)
- Use full file imports: `<<< @/../test/dummy/app/agents/agent_name.rb {ruby}`
- Use line ranges when needed: `<<< @/../test/dummy/app/agents/support_agent.rb#5-9 {ruby:line-numbers}`
- NO regions needed for implementation files

#### For Test Code Snippets
- Add regions around important test code:
```ruby
# region unique_region_name
code_to_include
# endregion unique_region_name
```
- Import with: `<<< @/../test/agents/test_file.rb#unique_region_name {ruby:line-numbers}`

#### For Test Output Examples
- Call `doc_example_output(response)` in tests to generate example files
- Include in docs with:
```markdown
::: details Response Example
<!-- @include: @/parts/examples/test-name.md -->
:::
```

### 3. Key Files Created/Modified

#### Test Files with Regions
- `test/agents/data_extraction_agent_test.rb` - Added regions and doc_example_output calls
- `test/agents/translation_agent_test.rb` - Added regions and doc_example_output calls
- `test/agents/support_agent_test.rb` - Added regions for tool usage examples
- `test/agents/application_agent_test.rb` - Added doc_example_output calls
- `test/agents/streaming_agent_test.rb` - Added regions for streaming examples
- `test/agents/callback_agent_test.rb` - Created new test for callback examples
- `test/agents/queued_generation_test.rb` - Created new test for queued generation
- `test/configuration_examples_test.rb` - Created for configuration documentation
- `test/generation_provider_examples_test.rb` - Created for provider examples
- `test/tool_configuration_test.rb` - Created for tool configuration examples

#### Enhanced Framework Files
- `lib/active_agent/generation_provider/response.rb` - Added `usage` method and token helpers

#### Updated Documentation
- `docs/docs/agents/data-extraction-agent.md` - Uses test regions, includes tabbed response examples
- `docs/docs/agents/translation-agent.md` - Created with test examples
- `docs/docs/action-prompt/tools.md` - Updated to use real implementation files
- `docs/docs/active-agent/generation.md` - Added response examples
- `docs/docs/active-agent/callbacks.md` - Updated to use test regions
- `docs/docs/active-agent/queued-generation.md` - Updated to use test regions
- `docs/docs/getting-started.md` - Removed hardcoded examples, uses real files

### 4. Documentation Rules

1. **NO hardcoded code blocks** - All code must come from tested files
2. **Use `<<<` imports only** - No manual code blocks
3. **Test everything** - If it's in docs, it must have a test
4. **Include outputs** - Use doc_example_output for response examples
5. **Line numbers** - Use `{ruby:line-numbers}` for test snippets

### 5. Remaining Tasks

From the todo list:
- [x] Create test for callbacks (before_action, after_generation)
- [x] Create test for queued generation (generate_later)
- [x] Create configuration test examples
- [x] Update getting-started.md to use test examples
- [x] Update callbacks.md to use test examples
- [ ] Update other docs to remove hardcoded examples

Files still needing review:
- `docs/docs/framework/generation-provider.md` - Has some hardcoded provider examples
- `docs/docs/framework/active-agent.md` - May have hardcoded examples
- `docs/docs/action-prompt/actions.md` - May have hardcoded examples
- `docs/docs/action-prompt/messages.md` - Needs review
- `docs/docs/action-prompt/prompts.md` - Needs review

### 6. Testing Process

1. Run new tests to generate VCR cassettes and example outputs:
   ```bash
   bin/test test/agents/callback_agent_test.rb
   bin/test test/agents/queued_generation_test.rb
   # etc...
   ```

2. Verify example outputs are generated in `docs/parts/examples/`

3. Build docs locally to verify imports work:
   ```bash
   bin/docs  # Starts vitepress dev server
   ```

### 7. VCR Cassette Management

- Keep existing cassettes that are committed
- Create new cassettes with unique names for new tests
- If API errors occur, ensure `test/dummy/config/master.key` is present
- Use descriptive cassette names that match the test purpose

### 8. Example Patterns

#### Simple Test Import
```markdown
<<< @/../test/agents/application_agent_test.rb#application_agent_prompt_context_message_generation{ruby:line-numbers}
```

#### Response Example with Tabs
```markdown
::: tabs

== Response Object

<!-- @include: @/parts/examples/test-parse-chart-response.md -->

== JSON Output

<!-- @include: @/parts/examples/test-parse-chart-json-response.md -->

:::
```

#### Implementation File Import
```markdown
<<< @/../test/dummy/app/agents/support_agent.rb {ruby}
```

This process ensures all documentation is accurate, tested, and maintainable.