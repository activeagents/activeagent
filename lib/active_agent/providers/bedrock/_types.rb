# frozen_string_literal: true

require_relative "options"
require_relative "bearer_client"
require_relative "../anthropic/_types"

# Bedrock uses the same request/response types as Anthropic.
# The BedrockClient handles all protocol translation internally.
