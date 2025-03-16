# frozen_string_literal: true

module ActiveAgent
  module QueuedGeneration
    extend ActiveSupport::Concern

    included do
      class_attribute :generation_job, default: ::ActiveAgent::GenerationJob
      class_attribute :generate_later_queue_name, default: :agents
    end
  end
end
