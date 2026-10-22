# frozen_string_literal: true

module ActionAgent
  # Full-window counts and chart buckets, independent of the capped trace
  # details. Read only scalar columns, never the potentially large spans.
  class TraceWindowReport
    MAX_BUCKETS = 180

    def initialize(scope, from:, to:, bucket_seconds:)
      @scope, @from, @to = scope, from, to
      duration = (to - from).ceil
      @bucket_seconds = bucket_seconds.to_i.clamp([ (duration.to_f / MAX_BUCKETS).ceil, 1 ].max, duration)
    end

    def as_json
      width = @bucket_seconds
      buckets = Array.new(((@to - @from) / width).ceil) do |index|
        tally.merge(start_ms: milliseconds(@from + index * width), end_ms: milliseconds([ @from + (index + 1) * width, @to ].min), agents: {})
      end
      total = tally
      @scope.in_batches(of: 1000) do |batch|
        batch.pluck(:timestamp, :agent_class, :status, :total_duration_ms).each do |timestamp, agent, status, duration|
          index = ((timestamp - @from) / width).floor
          next unless timestamp < @to && index >= 0 && index < buckets.size

          [ total, buckets[index] ].each do |counts|
            counts[:requests] += 1
            counts[:errors] += 1 if status == TelemetryTrace::STATUS_ERROR
            if duration && duration.finite?
              counts[:duration_sum] += duration
              counts[:duration_count] += 1
            end
          end
          agents = buckets[index][:agents]
          agents[agent] = agents.fetch(agent, 0) + 1 if agent
        end
      end
      {
        total_count: total[:requests],
        summary: summary(total).merge(throughput_per_minute: (total[:requests] * 60.0 / (@to - @from)).round(1)),
        window_start_ms: milliseconds(@from), window_end_ms: milliseconds(@to), bucket_seconds: width,
        buckets: buckets.map { |bucket| summary(bucket).merge(bucket.slice(:start_ms, :end_ms, :agents)) }
      }
    end

    private

    def tally
      { requests: 0, errors: 0, duration_sum: 0.0, duration_count: 0 }
    end

    def summary(counts)
      counts.slice(:requests, :errors).merge(avg_latency_ms: counts[:duration_count].positive? ? (counts[:duration_sum] / counts[:duration_count]).round : 0)
    end

    def milliseconds(time)
      (time.to_f * 1000).to_i
    end
  end
end
