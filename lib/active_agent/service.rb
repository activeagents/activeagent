# frozen_string_literal: true

module ActiveAgent
  class Service
    extend ActiveSupport::Autoload
    autoload :Configurator
    attr_accessor :name

    class << self
      def configure(service_name, configurations)
        Configurator.build(service_name, configurations)
      end

      def build(configurator:, name:, service: nil, **service_config) # :nodoc:
        new(**service_config).tap do |service_instance|
          service_instance.name = name
        end
      end
    end

    def generate(...)
      raise NotImplementedError
    end
  end
end
