# frozen_string_literal: true

module ActionAgent
  # The dashboard's aggregate queries are written portably, but a few of
  # them have a much faster PostgreSQL form (jsonb traversal, containment).
  # This is how those queries choose which one to run.
  module AdapterAware
    extend ActiveSupport::Concern

    class_methods do
      # True when the backing store is PostgreSQL.
      def postgres?
        connection.adapter_name.to_s.downcase.include?("postgres")
      end

      # SQL grouping +column+ into hourly buckets. PostgreSQL has
      # date_trunc; SQLite and MySQL get the equivalent format string.
      # Pair with hour_bucket_epoch, which normalises what each adapter
      # returns into epoch seconds so callers compare buckets the same way.
      def hour_bucket_sql(column = :timestamp)
        case connection.adapter_name.to_s.downcase
        when /postgres/ then "date_trunc('hour', #{column})"
        when /mysql/ then "DATE_FORMAT(#{column}, '%Y-%m-%d %H:00:00')"
        else "strftime('%Y-%m-%d %H:00:00', #{column})"
        end
      end

      # SQL matching rows whose JSON array +column+ actually has entries.
      #
      # `where.not(column: [])` cannot express this and is not a slower way
      # of doing it — Active Record reads the empty array as an empty IN
      # list, so the condition compiles to `1=1` and matches every row.
      # +column+ is always a literal from this codebase, never user input.
      def json_array_not_empty_sql(column)
        case connection.adapter_name.to_s.downcase
        when /postgres/ then "COALESCE(jsonb_array_length(#{column}::jsonb), 0) > 0"
        when /mysql/ then "COALESCE(JSON_LENGTH(#{column}), 0) > 0"
        else "COALESCE(json_array_length(#{column}), 0) > 0"
        end
      end

      # PostgreSQL hands back a Time; the others a UTC string.
      def hour_bucket_epoch(value)
        return value.to_i if value.is_a?(Time) || value.is_a?(DateTime)

        Time.find_zone("UTC").parse(value.to_s).to_i
      end
    end
  end
end
