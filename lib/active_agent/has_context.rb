# frozen_string_literal: true
module ActiveAgent
  module HasContext
    extend ActiveSupport::Concern

    class_methods do
      # Example:
      #   has_context prompts: :prompts, messages: :messages, tools: :actions
      #
      # Associations added:
      #   has_many :prompt_contexts (ActivePrompt::Context, as: :agent)
      #   has_many :prompts, :messages, :actions (through prompt_contexts/prompts)
      def has_context(prompts: :prompts, messages: :messages, tools: :actions)
        has_many :prompt_contexts,
                 class_name: "ActivePrompt::Context",
                 as: :agent,
                 dependent: :destroy,
                 inverse_of: :agent

        has_many prompts, through: :prompt_contexts, source: :prompt
        has_many messages, through: prompts, source: :messages
        has_many tools,    through: prompts, source: :actions

        define_method :add_prompt do |prompt, label: nil, metadata: {}|
          ActivePrompt::Context.create!(agent: self, prompt:, label:, metadata:)
        end

        define_method :remove_prompt do |prompt|
          prompt_contexts.where(prompt:).destroy_all
        end
      end
    end
  end
end
