# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    class Agent < ApplicationRecord
      include Ownable
      owned_by :user, :account

      has_many :agent_versions, dependent: :destroy
      has_many :agent_runs, dependent: :destroy
      has_many :evaluations, dependent: :destroy
      has_many :agent_memories, as: :memorable, dependent: :destroy

      # Polymorphic rows (agent_memories, agent_contexts) store this string.
      # A host app that grew these tables under its own Agent constant keeps
      # its existing rows readable by setting agent_polymorphic_name.
      def self.polymorphic_name
        ActiveAgent::Dashboard.agent_polymorphic_name || super
      end

      # Validations
      validates :name, presence: true, length: { minimum: 2, maximum: 100 }
      validates :slug, presence: true, format: { with: /\A[a-z0-9\-_]+\z/ }
      # Slugs are unique per owner. Which column that means depends on the
      # configured mode, so it is resolved at validation time rather than
      # baked into a uniqueness scope when the class loads.
      validate :slug_unique_within_owner
      validates :provider, presence: true
      validates :model, presence: true
      validate :validate_action_prompts

      # Status enum
      # `observed` agents were discovered from reported telemetry rather than
      # authored here. They can't be executed by the platform — we can't push
      # instructions into someone else's app — so they're read-only until forked.
      enum :status, { draft: 0, active: 1, archived: 2, observed: 3 }

      scope :observed_agents, -> { where(status: :observed) }
      scope :authored, -> { where.not(status: :observed) }

      # Callbacks
      before_validation :generate_slug, on: :create
      after_create :create_initial_version
      after_update :create_version_on_config_change, if: :configuration_changed?

      # Scopes
      scope :active_agents, -> { where(status: :active) }
      scope :by_provider, ->(provider) { where(provider: provider) }
      # jsonb containment on PostgreSQL; a substring match on the serialized
      # array everywhere else. The fallback can over-match a tool whose name
      # is a prefix of another, so the JSON quoting is kept in the pattern.
      scope :with_tool, ->(tool) {
        if postgres?
          where("tools @> ?", [ tool ].to_json)
        else
          where("tools LIKE ?", "%\"#{tool}\"%")
        end
      }

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
        terminal playwright filesystem code database slack fetch search edit translate memory agents
      ].freeze

      # Available providers
      PROVIDERS = %w[openai anthropic ollama openrouter].freeze

      # The ActiveAgent class name this agent's runs are recorded under — the
      # correlation key between platform Agent records and telemetry traces
      # (TelemetryTrace#agent_class) and solid_agent contexts.
      def telemetry_agent_class
        base = agent_class_name.presence || name.parameterize(separator: "_").camelize
        base.end_with?("Agent") ? base : "#{base}Agent"
      end

      # The agent's long-term memory (solid_agent HasMemory contract) — the
      # summary list its runs read/write via the memory tools.
      def memory
        AgentMemory.for(self)
      end

      # The default action every agent has; uses the base instructions alone.
      DEFAULT_ACTION = "ask"

      # All invokable action names: the default plus each named action prompt.
      def available_actions
        [ DEFAULT_ACTION ] + Array(action_prompts).filter_map { |ap| ap["name"].presence }
      end

      def action_prompt_for(action_name)
        Array(action_prompts).find { |ap| ap["name"] == action_name.to_s }
      end

      # The system instructions an action executes under: named actions stack
      # their prompt below the agent's base instructions; the default action
      # uses the base instructions alone.
      def composed_instructions_for(action_name)
        action = action_prompt_for(action_name)
        [ instructions, action&.dig("prompt") ].map(&:presence).compact.join("\n\n").presence
      end

      # Returns the configuration as a hash for versioning
      def configuration_snapshot
        {
          name: name,
          description: description,
          provider: provider,
          model: model,
          instructions: instructions,
          action_prompts: action_prompts,
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
          action_prompts: config["action_prompts"] || [],
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

      # Maps each historical instructions digest to the first version that
      # introduced it ("v3"), so run cohorts can label instruction changes with
      # real agent versions instead of raw hashes.
      def instructions_digest_versions
        agent_versions.order(:version_number).each_with_object({}) do |version, map|
          snapshot = version.configuration_snapshot
          base = snapshot["instructions"]
          label = "v#{version.version_number}"

          if base.present?
            map[Digest::SHA256.hexdigest(base).first(8)] ||= label
          end

          # Named actions run under composed instructions (base + action
          # prompt), so their runs carry a different digest per action.
          Array(snapshot["action_prompts"]).each do |action|
            composed = [ base, action["prompt"] ].map(&:presence).compact.join("\n\n")
            next if composed.blank?

            map[Digest::SHA256.hexdigest(composed).first(8)] ||= label
          end
        end
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
      def execute(input_prompt, action: nil, **params)
        run = agent_runs.create!(
          input_prompt: input_prompt,
          action_name: normalized_action(action),
          input_params: params,
          status: :pending,
          trace_id: SecureRandom.uuid
        )

        # Queue the execution job
        AgentExecutionJob.perform_later(run.id)

        run
      end

      # Quick test execution (synchronous)
      def test_execute(input_prompt, action: nil, **params)
        run = agent_runs.create!(
          input_prompt: input_prompt,
          action_name: normalized_action(action),
          input_params: params,
          status: :running,
          trace_id: SecureRandom.uuid,
          started_at: Time.current
        )

        begin
          # Build and execute the agent
          result = AgentExecutionService.call(self, run)

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

      def slug_unique_within_owner
        return if slug.blank?

        siblings = self.class.for_owner(owner)
        siblings = siblings.where.not(id: id) if persisted?
        errors.add(:slug, "has already been taken") if siblings.exists?(slug: slug)
      end

      def generate_slug
        return if slug.present?

        base_slug = name.to_s.parameterize
        self.slug = base_slug

        # Checked globally rather than per owner: a host app may have a global
        # unique index on slug (ours does), and suffixing costs one query.
        counter = 1
        while self.class.exists?(slug: slug)
          self.slug = "#{base_slug}-#{counter}"
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

      VERSIONED_FIELDS = %w[
        instructions action_prompts preset_type appearance instruction_sets
        tools mcp_servers model_config response_format
      ].freeze

      def configuration_changed?
        saved_changes.keys.any? { |key| VERSIONED_FIELDS.include?(key) }
      end

      def create_version_on_config_change
        next_version = (latest_version&.version_number || 0) + 1
        changed_fields = saved_changes.keys.select { |key| VERSIONED_FIELDS.include?(key) }

        agent_versions.create!(
          version_number: next_version,
          change_summary: "Updated: #{changed_fields.join(', ')}",
          configuration_snapshot: configuration_snapshot
        )
      end

      # Unknown action names fall back to the default rather than failing the
      # run — an action can be renamed between enqueue and execution.
      def normalized_action(action)
        action = action.to_s.presence
        action && available_actions.include?(action) ? action : nil
      end

      def validate_action_prompts
        return if action_prompts.blank?

        unless action_prompts.is_a?(Array) && action_prompts.all? { |ap| ap.is_a?(Hash) }
          errors.add(:action_prompts, "must be a list of action definitions")
          return
        end

        names = action_prompts.map { |ap| ap["name"].to_s }
        names.each do |action_name|
          unless action_name.match?(/\A[a-z][a-z0-9_]*\z/)
            errors.add(:action_prompts, "action name '#{action_name}' must be snake_case")
          end
          if action_name == DEFAULT_ACTION
            errors.add(:action_prompts, "'#{DEFAULT_ACTION}' is the built-in default action")
          end
        end
        errors.add(:action_prompts, "action names must be unique") if names.uniq.size != names.size
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
    end
  end
end
