# Example File Mapping

This document tracks the mapping between test files/methods and their generated example files.

## Current References to Update

### travel_agent_test.rb
- `test-travel-agent-search-action-with-LLM-interaction-test-travel-agent-search-action-with-LLM-interaction.md`
- `test-travel-agent-book-action-with-LLM-interaction-travel_agent_book_llm.md`
- `test-travel-agent-confirm-action-with-LLM-interaction-test-travel-agent-confirm-action-with-LLM-interaction.md`
- `test-travel-agent-full-conversation-flow-with-LLM-test-travel-agent-full-conversation-flow-with-LLM.md`
- `test-travel-agent-search-view-renders-HTML-format-test-travel-agent-search-view-renders-HTML-format.md`

### data_extraction_agent_test.rb
- `test-describe-cat-image-creates-a-multimodal-prompt-with-image-and-text-content-test-describe-cat-image-creates-a-multimodal-prompt-with-image-and-text-content.md`
- `test-parse-chart-content-from-image-data-test-parse-chart-content-from-image-data.md`
- `test-parse-chart-content-from-image-data-with-structured-output-schema-test-parse-chart-content-from-image-data-with-structured-output-schema.md`
- `test-parse-chart-content-from-image-data-with-structured-output-schema-parse-chart-json-response.md`
- `test-parse-resume-creates-a-multimodal-prompt-with-file-data-with-structured-output-schema-test-parse-resume-creates-a-multimodal-prompt-with-file-data-with-structured-output-schema.md`
- `test-parse-resume-creates-a-multimodal-prompt-with-file-data-with-structured-output-schema-parse-resume-json-response.md`

### support_agent_test.rb
- `test-it-renders-a-prompt-context-generates-a-response-with-a-tool-call-and-performs-the-requested-actions-test-it-renders-a-prompt-context-generates-a-response-with-a-tool-call-and-performs-the-requested-actions.md`

### translation_agent_test.rb
- `test-it-renders-a-translate-prompt-and-generates-a-translation-test-it-renders-a-translate-prompt-and-generates-a-translation.md`

### multi_turn_tool_test.rb
- `multi-turn-tool-test-agent-performs-tool-call-and-continues-generation-with-result.md`
- `multi-turn-tool-test-agent-chains-multiple-tool-calls-for-complex-task.md`

### option_hierarchy_test.rb
- `test-runtime-options-example-output-test-runtime-options-example-output.md`

### Unknown test file (need to find)
- `test-it-renders-a-prompt-with-an-plain-text-message-and-generates-a-response-test-it-renders-a-prompt-with-an-plain-text-message-and-generates-a-response.md`
- `test-it-renders-a-prompt-with-an-plain-text-message-with-previous-messages-and-generates-a-response-test-it-renders-a-prompt-with-an-plain-text-message-with-previous-messages-and-generates-a-response.md`
- `test-response-object-usage-test-response-object-usage.md`

## Files that reference these examples

1. **docs/docs/active-agent/travel-agent.md** - 5 references
2. **docs/docs/documentation-process.md** - 4 references  
3. **docs/docs/getting-started.md** - 1 reference
4. **docs/docs/active-agent/generation.md** - 2 references
5. **docs/docs/action-prompt/tools.md** - 1 reference
6. **docs/docs/agents/translation-agent.md** - 1 reference
7. **docs/docs/action-prompt/tool-calling.md** - 2 references
8. **docs/docs/action-prompt/actions.md** - 2 references
9. **docs/docs/framework/active-agent.md** - 3 references
10. **docs/docs/framework/generation-provider.md** - 1 reference
11. **docs/docs/agents/data-extraction-agent.md** - 6 references

## Expected New Naming Pattern

Based on the update, the new pattern should be:
`{test_file_name}-{test_method_name}.md`

For example:
- `support_agent_test-it_renders_a_prompt_context_generates_a_response_with_a_tool_call_and_performs_the_requested_actions.md`
- `multi_turn_tool_test-agent_performs_tool_call_and_continues_generation_with_result.md`
- `travel_agent_test-travel_agent_search_action_with_LLM_interaction.md`