# frozen_string_literal: true

module ActionAgent
  module Api
    class InstanceTiersController < ApplicationController
      before_action :set_tier, only: [ :show ]

      # GET /api/instance_tiers
      # List all available instance tiers
      def index
        tiers = SandboxInstanceTier.available

        # Filter by category if provided
        if params[:category].present?
          tiers = tiers.select { |t| t.category == params[:category] }
        end

        # Filter by GPU if requested
        if params[:gpu] == "true"
          tiers = tiers.select(&:has_gpu?)
        elsif params[:gpu] == "false"
          tiers = tiers.reject(&:has_gpu?)
        end

        render json: {
          tiers: tiers.map(&:as_json),
          categories: [
            { id: "free", name: "Free", description: "Basic instances for testing" },
            { id: "pro", name: "Pro", description: "Standard instances for production" },
            { id: "enterprise", name: "Enterprise", description: "High-performance instances" }
          ]
        }
      end

      # GET /api/instance_tiers/:id
      # Get a specific instance tier
      def show
        render json: { tier: @tier.as_json }
      end

      # GET /api/instance_tiers/recommend
      # Get recommended tier for a sandbox type
      def recommend
        sandbox_type = params[:sandbox_type] || "default"

        recommended = case sandbox_type
        when "playwright_mcp"
          SandboxInstanceTier.find(:cpu_medium)
        when "research"
          SandboxInstanceTier.find(:cpu_small)
        when "terminal"
          SandboxInstanceTier.find(:free)
        else
          SandboxInstanceTier.find(:cpu_small)
        end

        alternatives = SandboxInstanceTier.available.reject { |t| t.id == recommended.id }.take(3)

        render json: {
          recommended: recommended.as_json,
          alternatives: alternatives.map(&:as_json),
          sandbox_type: sandbox_type
        }
      end

      # GET /api/instance_tiers/pricing
      # Get pricing comparison
      def pricing
        tiers = SandboxInstanceTier.available

        render json: {
          cpu_tiers: tiers.select { |t| !t.has_gpu? }.map { |t|
            {
              id: t.id,
              name: t.name,
              specs: t.display_specs,
              hourly: t.hourly_cost.to_f,
              monthly: t.monthly_cost.to_f,
              category: t.category
            }
          },
          gpu_tiers: tiers.select(&:has_gpu?).map { |t|
            {
              id: t.id,
              name: t.name,
              specs: t.display_specs,
              hourly: t.hourly_cost.to_f,
              monthly: t.monthly_cost.to_f,
              category: t.category
            }
          },
          currency: "USD",
          billing_increment: "per second"
        }
      end

      private

      def set_tier
        @tier = SandboxInstanceTier.find(params[:id])
      rescue ArgumentError => e
        render json: { error: "Tier not found: #{params[:id]}" }, status: :not_found
      end
    end
  end
end
