# frozen_string_literal: true

module ActionAgent
  module Api
    class FeedbacksController < BaseController
      before_action :require_owner!

      def index
        traces = owned_traces
        traces = owner_agents.find(params[:agent_id]).telemetry_traces(traces) if params[:agent_id].present?
        scope = InteractionFeedback.where(telemetry_trace_id: traces.select(:id))
        if params[:rating].present?
          return render(json: { error: "Invalid rating" }, status: :bad_request) unless %w[positive negative].include?(params[:rating])
          scope = scope.where(rating: params[:rating])
        end
        scope = scope.where("created_at >= ?", date_start(params[:from])) if params[:from].present?
        scope = scope.where("created_at < ?", date_start(params[:to]) + 1.day) if params[:to].present?
        counts = scope.group(:rating).count
        total = counts.values.sum
        page = clamped_param(:page, default: 1, min: 1, max: 100_000)
        rows = scope.order(created_at: :desc, id: :desc).offset((page - 1) * 50).limit(50)
        trace_ids = ActionAgent.trace_model.where(id: rows.map(&:telemetry_trace_id)).pluck(:id, :trace_id).to_h
        render json: {
          feedback: rows.map { |row| row.as_json.merge("trace_id" => trace_ids[row.telemetry_trace_id]) },
          page: page, total: total, positive: counts.fetch("positive", 0), negative: counts.fetch("negative", 0),
          positive_percentage: total.zero? ? nil : (100.0 * counts.fetch("positive", 0) / total).round(1)
        }
      rescue Date::Error
        render json: { error: "Dates must use YYYY-MM-DD" }, status: :bad_request
      end

      private

      def date_start(value)
        date = Date.iso8601(value.to_s)
        Time.zone.local(date.year, date.month, date.day)
      end
    end
  end
end
