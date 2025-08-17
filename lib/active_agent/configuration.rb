# frozen_string_literal: true

module ActiveAgent
  class Configuration
    attr_accessor :verbose_generation_errors
    attr_accessor :generation_retry_errors
    attr_accessor :generation_max_retries
    attr_accessor :generation_provider_logger

    def initialize
      @verbose_generation_errors = false
      @generation_retry_errors = []
      @generation_max_retries = 3
      @generation_provider_logger = nil
    end

    def verbose_generation_errors?
      @verbose_generation_errors
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration if block_given?
      configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
