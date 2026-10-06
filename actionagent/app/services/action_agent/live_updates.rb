# frozen_string_literal: true

module ActionAgent
  # Used to tell clients subscribed to an Action Cable stream that a record
  # changed. A message is only { type:, id:, status: }, and a client that
  # wants the record refetches it over the JSON API, which checks who is
  # asking. The engine ships no channel classes, so a stream is only as
  # private as the host channel that serves it, and a message names the
  # record and its status and none of its content.
  #
  # Nothing is sent when the host has not loaded Action Cable; the dashboard
  # polls instead.
  module LiveUpdates
    class << self
      # Sends { type:, id:, status: } on +stream+.
      #
      # @return [Boolean] whether a message was sent
      def broadcast(stream, type:, id:, status:)
        return false unless available?

        ::ActionCable.server.broadcast(stream, { type: type.to_s, id: id, status: status&.to_s })
        true
      end

      # Whether the host loaded Action Cable.
      def available?
        defined?(::ActionCable) && ::ActionCable.respond_to?(:server) ? true : false
      end
    end
  end
end
