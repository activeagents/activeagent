# frozen_string_literal: true

module ActiveAgent
  # Configures asynchronous generation via Active Job.
  #
  # Provides class attributes to customize which job class processes
  # queued generations and which queue they run on. Enables agents to
  # defer prompt generation and embedding operations for background processing.
  #
  # @example Custom job class
  #   class MyAgent < ActiveAgent::Base
  #     self.generation_job = CustomGenerationJob
  #   end
  #
  # @example Custom queue name
  #   class PriorityAgent < ActiveAgent::Base
  #     self.generate_later_queue_name = :high_priority
  #   end
  #
  # @see ActiveAgent::GenerationJob
  module Queueing
    extend ActiveSupport::Concern

    included do
      # Job class used to process queued generations.
      #
      # @return [Class] defaults to ActiveAgent::GenerationJob
      class_attribute :generation_job, default: ::ActiveAgent::GenerationJob

      # Queue name for generation jobs.
      #
      # @return [Symbol] defaults to :agents
      class_attribute :generate_later_queue_name, default: :agents
    end
  end
end
