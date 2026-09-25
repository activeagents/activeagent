# frozen_string_literal: true

# Runs a block with the top-level `RubyLLM` constant replaced. Whether the real
# gem, the provider tests' stand-in for it, or neither is loaded depends on
# which tests ran first, and GET /api/provider_models lists the registry of
# whichever is there.
module RubyLLMConstant
  private

  # Runs the block with RubyLLM undefined, as in a host app that never
  # loads it.
  def without_ruby_llm(&)
    with_ruby_llm_constant(nil, &)
  end

  # Runs the block with `RubyLLM` set to `replacement` (undefined when nil),
  # then puts back whatever was there.
  def with_ruby_llm_constant(replacement)
    original = Object.send(:remove_const, :RubyLLM) if Object.const_defined?(:RubyLLM, false)
    Object.const_set(:RubyLLM, replacement) if replacement
    yield
  ensure
    Object.send(:remove_const, :RubyLLM) if Object.const_defined?(:RubyLLM, false)
    Object.const_set(:RubyLLM, original) if original
  end
end
