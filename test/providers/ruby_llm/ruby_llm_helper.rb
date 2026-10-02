# frozen_string_literal: true

require "ruby_llm"
require "minitest/mock"

# Shared by the RubyLLM tests that run unchanged on ruby_llm 1.16 and 2.x, in
# CI and locally. A test that can only see one side says so with
# skip_unless_ruby_llm_2!, and the two APIs' spellings live here.
module RubyLLMHelper
  # Stands in for a RubyLLM::Provider that answers complete from a script:
  # each request gets the next turn, a Message for a plain request or a list
  # of Chunks for a streamed one. Records the keywords of every request.
  class ScriptedProvider
    attr_reader :requests

    def initialize(*turns)
      @turns = turns
      @requests = []
    end

    def complete(_messages, tools:, temperature:, model:, **kwargs, &block)
      @requests << { tools: tools, temperature: temperature, model: model }.merge(kwargs)
      turn = @turns.shift

      if block
        turn.each { |chunk| block.call(chunk) }
        nil
      else
        turn
      end
    end
  end

  def ruby_llm_2?
    Gem::Version.new(::RubyLLM::VERSION) >= Gem::Version.new("2.0")
  end

  def skip_unless_ruby_llm_2!(what)
    skip "#{what} needs ruby_llm 2.0 or newer, #{::RubyLLM::VERSION} is loaded" unless ruby_llm_2?
  end

  # Runs the block with Models.resolve answering every model with provider.
  def with_ruby_llm_provider(provider, &block)
    model_class = defined?(::RubyLLM::Model::Info) ? ::RubyLLM::Model::Info : ::RubyLLM::Model
    resolve = ->(model_id, **_kwargs) { [ model_class.new(id: model_id, provider: "openai"), provider ] }

    ::RubyLLM::Models.stub(:resolve, resolve, &block)
  end

  # Message.new's keywords for token counts, which 2.0 renamed
  # (cached -> cache_read, cache_creation -> cache_write).
  def ruby_llm_token_attributes(input: nil, output: nil, cache_read: nil, cache_write: nil, thinking: nil)
    cache_keys = ruby_llm_2? ? %i[cache_read_tokens cache_write_tokens] : %i[cached_tokens cache_creation_tokens]

    {
      input_tokens: input,
      output_tokens: output,
      cache_keys.first => cache_read,
      cache_keys.last => cache_write,
      thinking_tokens: thinking
    }.compact
  end
end
