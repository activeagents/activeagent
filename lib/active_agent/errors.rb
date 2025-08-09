# frozen_string_literal: true

module ActiveAgent
  # = Active Agent Errors
  #
  # This module defines all custom error classes used throughout the ActiveAgent gem.
  # All custom errors inherit from ActiveAgentError which provides a common base
  # for catching any ActiveAgent-specific errors.
  module Errors
    # Base error class for all ActiveAgent errors
    class ActiveAgentError < StandardError; end

    # Base error for all generation provider related errors
    class GenerationProviderError < ActiveAgentError; end
  end
end
