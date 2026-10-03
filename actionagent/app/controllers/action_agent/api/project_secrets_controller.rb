# frozen_string_literal: true

module ActionAgent
  module Api
    # A project's secrets (the Environment tab): names, sources and who set
    # them, never values. Setting, replacing and removing one needs
    # :manage_project_secrets, and using the organization's provider key
    # :manage_credentials as well (see ProjectSecretAuthorization). A name
    # the sandbox sets itself, or one that changes how code is loaded, is
    # refused with 422 (see ProjectSecret).
    class ProjectSecretsController < BaseController
      include ProjectSecretAuthorization

      before_action :require_owner!
      before_action :set_project

      # GET /api/projects/:project_id/secrets
      def index
        render json: { secrets: summaries }
      end

      # PUT /api/projects/:project_id/secrets
      # { secrets: [{ name:, value: } | { name:, source: "organization_key", consent: true }] }
      # Sets every listed secret, replacing those that exist, or none of them
      # when one is refused. Each saved secret comes back with the warnings
      # its value raises (ProjectSecret.warnings_for).
      def upsert
        entries = params[:secrets]
        unless entries.is_a?(Array) && entries.all? { |entry| entry.respond_to?(:permit) }
          return render json: { error: "secrets must be a list of { name:, value: }" }, status: :bad_request
        end

        records = entries.map { |entry| assign(entry) }
        return unless records.all? { |record| authorize_secret!(record) }

        ProjectSecret.transaction { records.each(&:save!) }
        render json: { secrets: summaries, saved: records.map { |record| saved_json(record) } }
      end

      # PUT /api/projects/:project_id/secrets/:name { value: } or
      # { source: "organization_key", consent: true }
      def update
        record = assign(params)
        return unless authorize_secret!(record)

        record.save!
        render json: { secret: saved_json(record) }
      end

      # DELETE /api/projects/:project_id/secrets/:name
      def destroy
        record = @project.secrets.find_by!(name: params[:name])
        return unless authorize_action!(:manage_project_secrets, record)

        record.destroy!
        head :no_content
      end

      private

      def set_project
        @project = owned(Project).find(params[:project_id])
      end

      def assign(entry)
        attributes = entry.slice(:name, :value, :source, :consent).permit(:name, :value, :source, :consent).to_h
        @project.assign_secret(
          name: attributes["name"], value: attributes["value"], source: attributes["source"],
          consent: ActiveModel::Type::Boolean.new.cast(attributes["consent"]) == true, set_by: current_user
        )
      end

      def summaries
        records = @project.secrets.reload.ordered.to_a
        setters = setters_for(records)
        records.map { |record| record.as_summary(setters) }
      end

      def saved_json(record)
        record.as_summary(setters_for([ record ])).merge(warnings: record.warnings)
      end

      def setters_for(records)
        ids = records.filter_map(&:set_by_id).uniq
        user_class = ActionAgent.user_class&.safe_constantize
        ids.empty? || user_class.nil? ? {} : user_class.where(id: ids).index_by(&:id)
      end
    end
  end
end
