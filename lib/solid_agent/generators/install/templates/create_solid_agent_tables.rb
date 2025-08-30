# frozen_string_literal: true

class CreateSolidAgentTables < ActiveRecord::Migration<%= migration_version %>
  def change
    # region schema
    # Agent registry - tracks all agent classes in the system
    create_table :solid_agent_agents do |t|
      t.string :class_name, null: false
      t.string :display_name
      t.text :description
      t.string :status, default: "active"
      t.jsonb :metadata, default: {}
      t.timestamps
      
      t.index :class_name, unique: true
      t.index :status
    end

    # Agent configurations
    create_table :solid_agent_agent_configs do |t|
      t.references :agent, null: false, foreign_key: { to_table: :solid_agent_agents }
      t.string :environment
      t.jsonb :provider_settings, default: {}
      t.jsonb :default_options, default: {}
      t.boolean :tracking_enabled, default: true
      t.boolean :evaluation_enabled, default: false
      t.timestamps
      
      t.index [:agent_id, :environment], unique: true
    end

    # Prompt templates with versioning
    create_table :solid_agent_prompts do |t|
      t.references :agent, null: false, foreign_key: { to_table: :solid_agent_agents }
      t.string :action_name, null: false
      t.references :current_version, foreign_key: { to_table: :solid_agent_prompt_versions }
      t.jsonb :metadata, default: {}
      t.timestamps
      
      t.index [:agent_id, :action_name], unique: true
    end

    # Prompt versions
    create_table :solid_agent_prompt_versions do |t|
      t.references :prompt, null: false, foreign_key: { to_table: :solid_agent_prompts }
      t.integer :version_number, null: false
      t.text :template_content
      t.text :instructions
      t.jsonb :schema_definition
      t.boolean :active, default: false
      t.jsonb :metadata, default: {}
      t.timestamps
      
      t.index [:prompt_id, :version_number], unique: true
      t.index [:prompt_id, :active]
    end

    # Prompt contexts (not conversations!) - the full context of agent interactions
    create_table :solid_agent_prompt_contexts do |t|
      t.references :agent, null: false, foreign_key: { to_table: :solid_agent_agents }
      t.string :external_id
      t.string :contextual_type  # Polymorphic association type
      t.bigint :contextual_id    # Polymorphic association id
      t.string :context_type, default: "runtime"  # runtime, tool_execution, background_job, etc.
      t.string :status, default: "active"
      t.timestamp :started_at
      t.timestamp :completed_at
      t.jsonb :metadata, default: {}
      t.timestamps
      
      t.index :external_id, unique: true, where: "external_id IS NOT NULL"
      t.index [:contextual_type, :contextual_id]
      t.index [:status, :created_at]
      t.index :context_type
    end

    # Messages - system, user, assistant, tool
    create_table :solid_agent_messages do |t|
      t.references :prompt_context, null: false, 
                   foreign_key: { to_table: :solid_agent_prompt_contexts }
      t.string :role, null: false  # system, user, assistant, tool
      t.text :content
      t.string :content_type, default: "text"  # text, html, json, multimodal, structured
      t.integer :position, null: false
      t.jsonb :metadata, default: {}
      t.timestamps
      
      t.index [:prompt_context_id, :position]
      t.index :role
    end

    # Actions (tool/function calls)
    create_table :solid_agent_actions do |t|
      t.references :message, null: false, foreign_key: { to_table: :solid_agent_messages }
      t.string :action_name, null: false
      t.string :action_id, null: false
      t.jsonb :parameters, default: {}
      t.string :status, default: "pending"
      t.timestamp :executed_at
      t.timestamp :completed_at
      t.references :result_message, foreign_key: { to_table: :solid_agent_messages }
      t.integer :latency_ms
      t.jsonb :metadata, default: {}
      t.timestamps
      
      t.index :action_id, unique: true
      t.index :status
      t.index [:message_id, :status]
    end

    # Generations - tracks each AI generation request
    create_table :solid_agent_generations do |t|
      t.references :prompt_context, null: false,
                   foreign_key: { to_table: :solid_agent_prompt_contexts }
      t.references :message, foreign_key: { to_table: :solid_agent_messages }
      t.references :prompt_version, foreign_key: { to_table: :solid_agent_prompt_versions }
      t.string :provider, null: false
      t.string :model, null: false
      t.integer :prompt_tokens
      t.integer :completion_tokens
      t.integer :total_tokens
      t.decimal :cost, precision: 10, scale: 6
      t.integer :latency_ms
      t.string :status, default: "pending"
      t.text :error_message
      t.timestamp :started_at
      t.timestamp :completed_at
      t.jsonb :options, default: {}
      t.jsonb :metadata, default: {}
      t.timestamps
      
      t.index [:prompt_context_id, :created_at]
      t.index [:provider, :model]
      t.index [:status, :created_at]
    end

    # Evaluations - for quality metrics and feedback
    create_table :solid_agent_evaluations do |t|
      t.string :evaluatable_type, null: false  # Polymorphic
      t.bigint :evaluatable_id, null: false
      t.string :evaluation_type, null: false  # human, automated, hybrid
      t.decimal :score, precision: 5, scale: 2
      t.text :feedback
      t.jsonb :metrics, default: {}
      t.string :evaluator_type  # Polymorphic for evaluator
      t.bigint :evaluator_id
      t.timestamps
      
      t.index [:evaluatable_type, :evaluatable_id]
      t.index [:evaluation_type, :score]
      t.index [:evaluator_type, :evaluator_id]
    end

    # Usage metrics - aggregated metrics per agent
    create_table :solid_agent_usage_metrics do |t|
      t.references :agent, null: false, foreign_key: { to_table: :solid_agent_agents }
      t.date :date, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.integer :total_requests, default: 0
      t.integer :total_tokens, default: 0
      t.decimal :total_cost, precision: 10, scale: 2, default: 0
      t.integer :error_count, default: 0
      t.integer :avg_latency_ms
      t.jsonb :metadata, default: {}
      t.timestamps
      
      t.index [:agent_id, :date, :provider, :model], unique: true,
              name: "idx_usage_metrics_unique"
      t.index [:date, :provider]
    end

    # Performance metrics - for monitoring
    create_table :solid_agent_performance_metrics do |t|
      t.references :agent, null: false, foreign_key: { to_table: :solid_agent_agents }
      t.timestamp :recorded_at, null: false
      t.string :metric_type, null: false  # latency, throughput, error_rate, etc.
      t.decimal :value, precision: 10, scale: 4
      t.string :unit
      t.jsonb :dimensions, default: {}  # Additional dimensions for filtering
      t.jsonb :metadata, default: {}
      t.timestamps
      
      t.index [:agent_id, :metric_type, :recorded_at]
      t.index [:recorded_at, :metric_type]
    end
  end
end