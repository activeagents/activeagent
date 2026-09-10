# frozen_string_literal: true

module ActionAgent
  module Api
    # Edits to a conversation context from the agent runner: seed a user or
    # assistant turn without running the agent, fix a turn's text, or drop
    # one — so the next run sees exactly the history the tester intends.
    #
    # Only user and assistant turns are editable. Tool and system rows are
    # written by execution and read back as call/result pairs; half a pair
    # is worse than an uneditable one.
    class InteractionMessagesController < BaseController
      EDITABLE_ROLES = %w[user assistant].freeze

      # Marks turns typed into the context by hand, as opposed to the
      # provenance SolidAgent stamps on turns a run produced.
      MANUAL_PROVENANCE = { "source" => "dashboard", "manual" => true }.freeze

      rescue_from Agent::ObservedAgentError, with: :observed_agent_read_only

      before_action :require_owner!
      before_action :set_context
      before_action :require_executable_agent!, only: [ :create, :update, :destroy ]
      before_action :set_message, only: [ :update, :destroy ]

      # POST /api/interactions/:interaction_id/messages
      def create
        role = params[:role].to_s
        unless EDITABLE_ROLES.include?(role)
          return render json: { error: "role must be user or assistant" }, status: :unprocessable_entity
        end

        content = params[:content].to_s
        return render json: { error: "content can't be blank" }, status: :unprocessable_entity if content.blank?

        message = @context.messages.create!(
          role: role,
          content: content,
          content_checksum: Digest::MD5.hexdigest(content),
          provenance: MANUAL_PROVENANCE
        )
        @context.touch

        render json: { message: AgentMessageSerializer.call(message) }, status: :created
      end

      # PATCH /api/interactions/:interaction_id/messages/:id
      def update
        content = params[:content].to_s
        return render json: { error: "content can't be blank" }, status: :unprocessable_entity if content.blank?

        @message.update!(content: content, content_checksum: Digest::MD5.hexdigest(content))
        @context.touch

        render json: { message: AgentMessageSerializer.call(@message) }
      end

      # DELETE /api/interactions/:interaction_id/messages/:id
      def destroy
        @message.destroy!
        @context.touch

        head :no_content
      end

      private

      def set_context
        @context = AgentContext.for_agents(owner_agents).find(params[:interaction_id])
      end

      # Seeding, fixing or dropping a turn writes the agent's own history, so
      # it answers to the same read-only policy execution does (#414): an
      # observed agent is a mirror of someone else's telemetry, and a turn
      # typed in here would be a fabrication attributed to it. Asked of the
      # agent rather than re-tested here, so `observed` has one definition and
      # one message. Reads are left open — every action this controller has is
      # a write; the conversation itself is still listed and shown.
      def require_executable_agent!
        agent = @context.contextable
        agent.ensure_executable! if agent.respond_to?(:ensure_executable!)
      end

      def observed_agent_read_only(exception)
        render json: { error: exception.message }, status: :unprocessable_entity
      end

      # Looked up through the context, so a message id from another
      # conversation is a 404 rather than a cross-conversation edit.
      def set_message
        @message = @context.messages.find(params[:id])
        return if EDITABLE_ROLES.include?(@message.role)

        render json: { error: "Only user and assistant messages can be edited" }, status: :unprocessable_entity
      end
    end
  end
end
