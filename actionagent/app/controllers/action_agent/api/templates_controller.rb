# frozen_string_literal: true

module ActionAgent
  module Api
    class TemplatesController < BaseController
      # No anonymous exemption: #show looks a template up by bare id, so the
      # exemption served unpublished drafts and private prompt libraries to
      # anyone walking the id space. #index was already limited to public
      # templates; #show was not.

      # GET /api/templates
      def index
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
      def use
        @template = AgentTemplate.find(params[:id])

        agent = @template.create_agent_for(
          current_user,
          name: params[:name] || @template.name
        )

        if agent.persisted?
          render json: { agent: agent_json(agent) }, status: :created
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

      def agent_json(agent)
        {
          id: agent.id,
          name: agent.name,
          slug: agent.slug,
          description: agent.description,
          provider: agent.provider,
          model: agent.model,
          status: agent.status,
          preset_type: agent.preset_type,
          appearance: agent.appearance
        }
      end
    end
  end
end
