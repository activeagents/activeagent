# frozen_string_literal: true

module ActionAgent
  module Api
    class TemplatesController < BaseController
      include AgentSerialization

      # No anonymous exemption: #show looks a template up by bare id, so the
      # exemption served unpublished drafts and private prompt libraries to
      # anyone walking the id space. #index was already limited to public
      # templates; #show was not.

      before_action :require_owner!, only: [ :use ]

      # GET /api/templates
      def index
        # The library ships with the engine but nothing ever seeded it, so a
        # fresh install showed "No templates found" behind every Browse
        # Templates button. seed_defaults! is idempotent (find_or_create_by!
        # on slug), so an empty table is seeded on first read; the
        # action_agent:seed_templates task does the same on demand.
        AgentTemplate.seed_defaults! if AgentTemplate.none?

        @templates = AgentTemplate.public_templates.order(usage_count: :desc)

        # Filter by category
        @templates = @templates.by_category(params[:category]) if params[:category].present?

        # Featured only
        @templates = @templates.featured if params[:featured].present?

        render json: {
          templates: @templates.map { |t| template_json(t) },
          categories: AgentTemplate::CATEGORIES
        }
      end

      # GET /api/templates/:id
      def show
        @template = AgentTemplate.find(params[:id])
        render json: { template: template_json(@template, include_details: true) }
      end

      # POST /api/templates/:id/use
      #
      # Built through the engine's ownership layer (owner_agents, as
      # AgentsController#create does) rather than the host user's `agents`
      # association: a single-user install has no user, and the old
      # `current_user.agents.build` raised NoMethodError on nil for every
      # click of "Use This Template".
      def use
        @template = AgentTemplate.find(params[:id])
        agent = @template.build_agent_in(owner_agents, name: params[:name])

        if agent.save
          @template.increment!(:usage_count)
          # The detail shape, not a summary: the dashboard opens the new agent
          # in the editor straight from this response, and an editor seeded
          # from a summary saved empty instructions/tools/model_config over
          # the template's real ones.
          render json: { agent: agent_json(agent, include_details: true) }, status: :created
        else
          render json: { errors: agent.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def template_json(template, include_details: false)
        json = {
          id: template.id,
          name: template.name,
          slug: template.slug,
          description: template.description,
          category: template.category,
          provider: template.provider,
          model: template.model,
          preset_type: template.preset_type,
          appearance: template.appearance,
          icon: template.icon,
          usage_count: template.usage_count,
          featured: template.featured,
          tools: template.tools
        }

        if include_details
          json.merge!(
            instructions: template.instructions,
            instruction_sets: template.instruction_sets,
            model_config: template.model_config
          )
        end

        json
      end
    end
  end
end
