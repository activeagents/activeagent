# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Represents an AI agent configuration.
    #
    # Agents are the core entity in the dashboard, storing all configuration
    # needed to execute AI interactions including provider settings, instructions,
    # tools, and appearance.
    #
    # Supports both local (single-user) and multi-tenant (account-scoped) modes.
    #
    # @example Creating an agent
    #   agent = ActiveAgent::Dashboard::Agent.create!(
    #     name: "Code Assistant",
    #     provider: "openai",
    #     model: "gpt-4o"
    #   )
    #
    # @example Executing an agent
    #   run = agent.execute("Explain this code", code: "def foo; end")
    #
    class Agent < ApplicationRecord
      # Associations - owner is optional to support both modes
      belongs_to :user, class_name: ActiveAgent::Dashboard.user_class, optional: true if ActiveAgent::Dashboard.user_class
      belongs_to :account, class_name: ActiveAgent::Dashboard.account_class, optional: true if ActiveAgent::Dashboard.multi_tenant?

      has_many :agent_versions, class_name: "ActiveAgent::Dashboard::AgentVersion", dependent: :destroy
      has_many :agent_runs, class_name: "ActiveAgent::Dashboard::AgentRun", dependent: :destroy

      # Validations
      validates :name, presence: true, length: { minimum: 2, maximum: 100 }
      validates :slug, presence: true, format: { with: /\A[a-z0-9\-_]+\z/ }
      validates :provider, presence: true
      validates :model, presence: true

      # Ensure slug uniqueness within scope
      if ActiveAgent::Dashboard.multi_tenant?
        validates :slug, uniqueness: { scope: :account_id }
      else
        validates :slug, uniqueness: { scope: :user_id }
      end

      # Status enum
      enum :status, { draft: 0, active: 1, archived: 2 }

      # Callbacks
      before_validation :generate_slug, on: :create
      after_create :create_initial_version
      after_update :create_version_on_config_change, if: :configuration_changed?

      # Scopes
      scope :active_agents, -> { where(status: :active) }
      scope :by_provider, ->(provider) { where(provider: provider) }
      scope :with_tool, ->(tool) { where("tools @> ?", [ tool ].to_json) }

      # Available presets matching AgentAvatar component
      PRESET_TYPES = %w[
        terminal webDeveloper documentAnalysis writing translation
        playwright research imageAnalysis computerUse productDesign
      ].freeze

      # Available instruction sets
      INSTRUCTION_SETS = %w[
        github ruby rails aws gcp python typescript docker kubernetes
      ].freeze

      # Available tools/MCPs
      AVAILABLE_TOOLS = %w[
        terminal playwright filesystem code database slack fetch search edit translate memory
      ].freeze

      # Available providers
      PROVIDERS = %w[openai anthropic ollama openrouter].freeze

      # Returns the configuration as a hash for versioning
      def configuration_snapshot
        {
          name: name,
          description: description,
          provider: provider,
          model: model,
          instructions: instructions,
          preset_type: preset_type,
          appearance: appearance,
          instruction_sets: instruction_sets,
          tools: tools,
          mcp_servers: mcp_servers,
          model_config: model_config,
          response_format: response_format
        }
      end

      # Restore from a version
      def restore_from_version!(version)
        config = version.configuration_snapshot
        update!(
          instructions: config["instructions"],
          preset_type: config["preset_type"],
          appearance: config["appearance"],
          instruction_sets: config["instruction_sets"],
          tools: config["tools"],
          mcp_servers: config["mcp_servers"],
          model_config: config["model_config"],
          response_format: config["response_format"]
        )
      end

      # Get the latest version
      def latest_version
        agent_versions.order(version_number: :desc).first
      end

      # Get version count
      def version_count
        agent_versions.count
      end

      # Generate Ruby agent class code
      def to_agent_class_code
        <<~RUBY
          class #{agent_class_name || name.camelize}Agent < ApplicationAgent
            generate_with :#{provider}, model: "#{model}"#{model_config_code}

            def perform
              prompt#{instructions_code}
            end
          end
        RUBY
      end

      # Execute a run with this agent
      def execute(input_prompt, **params)
        run = agent_runs.create!(
          input_prompt: input_prompt,
          input_params: params,
          status: :pending,
          trace_id: SecureRandom.uuid
        )

        # Queue the execution job
        ActiveAgent::Dashboard::AgentExecutionJob.perform_later(run.id)

        run
      end

      # Quick test execution (synchronous)
      def test_execute(input_prompt, **params)
        run = agent_runs.create!(
          input_prompt: input_prompt,
          input_params: params,
          status: :running,
          trace_id: SecureRandom.uuid,
          started_at: Time.current
        )

        begin
          result = build_and_execute_agent(input_prompt, **params)

          run.update!(
            output: result[:output],
            output_metadata: result[:metadata],
            status: :complete,
            completed_at: Time.current,
            duration_ms: ((Time.current - run.started_at) * 1000).to_i,
            input_tokens: result.dig(:usage, :input_tokens),
            output_tokens: result.dig(:usage, :output_tokens),
            total_tokens: result.dig(:usage, :total_tokens)
          )
        rescue => e
          run.update!(
            status: :failed,
            completed_at: Time.current,
            error_message: e.message,
            error_backtrace: e.backtrace&.first(10)&.join("\n")
          )
        end

        run
      end

      private

      def generate_slug
        return if slug.present?

        base_slug = name.to_s.parameterize
        self.slug = base_slug

        # Ensure uniqueness within scope
        counter = 1
        scope = self.class.where(slug: slug)
        scope = scope.where(account_id: account_id) if respond_to?(:account_id) && account_id
        scope = scope.where(user_id: user_id) if respond_to?(:user_id) && user_id

        while scope.exists?
          self.slug = "#{base_slug}-#{counter}"
          scope = self.class.where(slug: slug)
          scope = scope.where(account_id: account_id) if respond_to?(:account_id) && account_id
          scope = scope.where(user_id: user_id) if respond_to?(:user_id) && user_id
          counter += 1
        end
      end

      def create_initial_version
        agent_versions.create!(
          version_number: 1,
          change_summary: "Initial creation",
          configuration_snapshot: configuration_snapshot
        )
      end

      def configuration_changed?
        saved_changes.keys.any? do |key|
          %w[instructions preset_type appearance instruction_sets tools mcp_servers model_config response_format].include?(key)
        end
      end

      def create_version_on_config_change
        next_version = (latest_version&.version_number || 0) + 1
        changed_fields = saved_changes.keys.select do |key|
          %w[instructions preset_type appearance instruction_sets tools mcp_servers model_config response_format].include?(key)
        end

        agent_versions.create!(
          version_number: next_version,
          change_summary: "Updated: #{changed_fields.join(', ')}",
          configuration_snapshot: configuration_snapshot
        )
      end

      def model_config_code
        return "" if model_config.blank?

        configs = model_config.map { |k, v| "#{k}: #{v.inspect}" }.join(", ")
        ", #{configs}"
      end

      def instructions_code
        return "" if instructions.blank?

        "\n    prompt instructions: <<~INSTRUCTIONS\n      #{instructions.gsub("\n", "\n      ")}\n    INSTRUCTIONS"
      end

      def build_and_execute_agent(input_prompt, **params)
        # TODO: Implement actual ActiveAgent execution
        # This will create a dynamic agent class and execute it
        {
          output: "Mock response for: #{input_prompt}",
          metadata: { provider: provider, model: model },
          usage: { input_tokens: 10, output_tokens: 20, total_tokens: 30 }
        }
      end
    end
  end
end
