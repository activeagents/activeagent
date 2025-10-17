# frozen_string_literal: true

require_relative "../../../common/_base_model"

module ActiveAgent
  module Providers
    module Ollama
      module Embedding
        module Requests
          class Options < Common::BaseModel
            # Enable Mirostat sampling for controlling perplexity
            # 0 = disabled, 1 = Mirostat, 2 = Mirostat 2.0 (default: 0)
            attribute :mirostat, :integer

            # Influences how quickly the algorithm responds to feedback from the generated text
            # Lower learning rate = slower adjustments, higher = more responsive (default: 0.1)
            attribute :mirostat_eta, :float

            # Controls the balance between coherence and diversity of the output
            # Lower value = more focused and coherent text (default: 5.0)
            attribute :mirostat_tau, :float

            # Sets the size of the context window used to generate the next token (default: 2048)
            attribute :num_ctx, :integer

            # Sets how far back for the model to look back to prevent repetition
            # Default: 64, 0 = disabled, -1 = num_ctx
            attribute :repeat_last_n, :integer

            # Sets how strongly to penalize repetitions
            # Higher value (e.g., 1.5) = stronger penalty, lower (e.g., 0.9) = more lenient (default: 1.1)
            attribute :repeat_penalty, :float

            # The temperature of the model
            # Higher temperature = more creative answers (default: 0.8)
            attribute :temperature, :float

            # Sets the random number seed to use for generation
            # Setting this to a specific number will make the model generate the same text for the same prompt (default: 0)
            attribute :seed, :integer

            # Sets the stop sequences to use
            # When this pattern is encountered the LLM will stop generating text and return
            # Can be a string or array of strings
            attribute :stop

            # Maximum number of tokens to predict when generating text
            # Default: -1 (infinite generation)
            attribute :num_predict, :integer

            # Reduces the probability of generating nonsense
            # Higher value (e.g. 100) = more diverse answers, lower (e.g. 10) = more conservative (default: 40)
            attribute :top_k, :integer

            # Works together with top-k
            # Higher value (e.g., 0.95) = more diverse text, lower (e.g., 0.5) = more focused and conservative (default: 0.9)
            attribute :top_p, :float

            # Alternative to the top_p, and aims to ensure a balance of quality and variety
            # Represents the minimum probability for a token to be considered, relative to the probability of the most likely token
            # For example, with p=0.05 and the most likely token having a probability of 0.9,
            # logits with a value less than 0.045 are filtered out (default: 0.0)
            attribute :min_p, :float

            # Validations
            validates :mirostat,       inclusion: { in: [ 0, 1, 2 ] },                                          allow_nil: true
            validates :mirostat_eta,   numericality: { greater_than_or_equal_to: 0 },                           allow_nil: true
            validates :mirostat_tau,   numericality: { greater_than_or_equal_to: 0 },                           allow_nil: true
            validates :num_ctx,        numericality: { greater_than: 0, only_integer: true },                   allow_nil: true
            validates :repeat_last_n,  numericality: { greater_than_or_equal_to: -1, only_integer: true },      allow_nil: true
            validates :repeat_penalty, numericality: { greater_than: 0 },                                       allow_nil: true
            validates :temperature,    numericality: { greater_than_or_equal_to: 0 },                           allow_nil: true
            validates :seed,           numericality: { only_integer: true },                                    allow_nil: true
            validates :num_predict,    numericality: { greater_than_or_equal_to: -1, only_integer: true },      allow_nil: true
            validates :top_k,          numericality: { greater_than: 0, only_integer: true },                   allow_nil: true
            validates :top_p,          numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
            validates :min_p,          numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true

            validate :validate_stop_format

            private

            def validate_stop_format
              return if stop.nil?

              unless stop.is_a?(String) || stop.is_a?(Array)
                errors.add(:stop, "must be a string or array of strings")
                return
              end

              if stop.is_a?(Array)
                stop.each_with_index do |item, index|
                  unless item.is_a?(String)
                    errors.add(:stop, "array elements must be strings at index #{index}")
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
