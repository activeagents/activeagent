# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module OpenRouter
      # Base class for OpenRouter request objects with ActiveModel support
      class ConfigObject
        include ActiveModel::Model
        include ActiveModel::Attributes
        include ActiveModel::Validations

        def self.alias_names = []

        def self.accepts_attributes_for(association_name, klass)
          attributes = klass.attribute_names | klass.alias_names

          attributes.each do |attribute|
            define_method(attribute) do
              public_send(association_name)&.public_send(attribute)
            end

            define_method("#{attribute}=") do |value|
              unless public_send(association_name)
                public_send("#{association_name}=", {})
              end

              public_send(association_name).public_send("#{attribute}=", value)
            end
          end
        end

        def to_h
          attributes.compact.transform_values do |value|
            case value
            when ConfigObject
              value.to_h
            when Array
              value.map { |v| v.is_a?(ConfigObject) ? v.to_h : v }
            else
              value
            end
          end
        end

        alias_method :to_hash, :to_h
      end

      # Text content part for messages
      class TextContent < ConfigObject
        attribute :type, :string, default: "text"
        attribute :text, :string

        validates :type, inclusion: { in: %w[text] }
        validates :text, presence: true
      end

      # Image content part for messages
      class ImageContentPart < ConfigObject
        attribute :type, :string, default: "image_url"
        attribute :image_url, default: -> { {} }

        validates :type, inclusion: { in: %w[image_url] }
        validates :image_url, presence: true

        def image_url=(value)
          if value.is_a?(Hash)
            super({
              url: value[:url] || value["url"],
              detail: value[:detail] || value["detail"]
            }.compact)
          else
            super(value)
          end
        end

        validate :validate_image_url_structure

        private

        def validate_image_url_structure
          return if image_url.blank?
          return unless image_url.is_a?(Hash)

          if image_url[:url].blank? && image_url["url"].blank?
            errors.add(:image_url, "must contain a url")
          end
        end
      end

      # Message object for chat completions
      class Message < ConfigObject
        attribute :role, :string
        attribute :content # Can be string or array of ContentParts
        attribute :name, :string
        attribute :tool_call_id, :string

        validates :role, presence: true, inclusion: { in: %w[user assistant system tool] }
        validates :content, presence: true

        validate :validate_role_specific_fields

        def content=(value)
          if value.is_a?(Array)
            super(value.map do |part|
              next part if part.is_a?(TextContent) || part.is_a?(ImageContentPart)

              case part
              when Hash
                if part[:type] == "text" || part["type"] == "text"
                  TextContent.new(part)
                elsif part[:type] == "image_url" || part["type"] == "image_url"
                  ImageContentPart.new(part)
                else
                  part
                end
              else
                part
              end
            end)
          else
            super(value)
          end
        end

        private

        def validate_role_specific_fields
          if role == "tool"
            errors.add(:tool_call_id, "is required for tool role") if tool_call_id.blank?
          elsif role == "user" && content.is_a?(Array)
            # ContentParts are only valid for user role
            content.each_with_index do |part, index|
              next if part.is_a?(String)
              next if part.is_a?(TextContent) || part.is_a?(ImageContentPart)

              errors.add(:content, "invalid content part at index #{index}")
            end
          end
        end
      end

      # Function description for tools
      class FunctionDescription < ConfigObject
        attribute :name, :string
        attribute :description, :string
        attribute :parameters, default: -> { {} } # JSON Schema object

        validates :name, presence: true
        validates :parameters, presence: true

        validate :validate_parameters_is_object

        private

        def validate_parameters_is_object
          return if parameters.blank?
          unless parameters.is_a?(Hash)
            errors.add(:parameters, "must be a JSON Schema object (Hash)")
          end
        end
      end

      # Tool definition
      class Tool < ConfigObject
        attribute :type, :string, default: "function"
        attribute :function

        validates :type, inclusion: { in: %w[function] }
        validates :function, presence: true

        def function=(value)
          if value.is_a?(Hash) && !value.is_a?(FunctionDescription)
            super(FunctionDescription.new(value))
          else
            super(value)
          end
        end

        validate :validate_function_object

        private

        def validate_function_object
          return if function.blank?

          if function.is_a?(FunctionDescription)
            unless function.valid?
              function.errors.full_messages.each do |msg|
                errors.add(:function, msg)
              end
            end
          elsif !function.is_a?(Hash)
            errors.add(:function, "must be a FunctionDescription or Hash")
          end
        end
      end

      # Tool choice for controlling tool usage
      class ToolChoice < ConfigObject
        attribute :type, :string
        attribute :function, default: -> { {} }

        validates :type, inclusion: { in: %w[function] }, if: -> { type.present? }

        validate :validate_tool_choice_format

        # Allow simple string values like "none" or "auto"
        def self.from_value(value)
          case value
          when String
            # Return the string directly for "none" or "auto"
            value
          when Hash
            new(value)
          else
            value
          end
        end

        private

        def validate_tool_choice_format
          return if type.blank?

          if type == "function"
            if function.blank? || (function.is_a?(Hash) && function[:name].blank? && function["name"].blank?)
              errors.add(:function, "must contain a name when type is 'function'")
            end
          end
        end
      end

      # Provider preferences for routing
      class ProviderPreferences < ConfigObject
        attribute :allow_fallbacks, :boolean
        attribute :require_parameters, :boolean
        attribute :data_collection, :string
        attribute :order, default: -> { [] }
        attribute :ignore, default: -> { [] }
        attribute :quantizations, default: -> { [] }

        validates :data_collection,
                  inclusion: { in: %w[allow deny] },
                  allow_nil: true

        validate :validate_order_and_ignore_arrays

        private

        def validate_order_and_ignore_arrays
          if order.present? && !order.is_a?(Array)
            errors.add(:order, "must be an array of provider names")
          end

          if ignore.present? && !ignore.is_a?(Array)
            errors.add(:ignore, "must be an array of provider names")
          end

          if quantizations.present? && !quantizations.is_a?(Array)
            errors.add(:quantizations, "must be an array")
          end
        end
      end

      # Response format specification
      class ResponseFormat < ConfigObject
        attribute :type, :string

        validates :type, inclusion: { in: %w[json_object] }
      end

      # Prediction for latency optimization
      class Prediction < ConfigObject
        attribute :type, :string
        attribute :content, :string

        validates :type, inclusion: { in: %w[content] }
        validates :content, presence: true
      end

      # Extra Headers
      class Header < ConfigObject
        attribute :http_referer, :string
        attribute :x_title, :string

        validates :http_referer, format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]), message: "must be a valid URL" }, allow_nil: true

        alias_attribute :site_url, :http_referer
        alias_attribute :app_name, :x_title

        def self.alias_names
          [ "site_url", "app_name" ]
        end

        def to_h
          {
            "HTTP-Referer" => http_referer,
            "X-Title" => x_title
          }.compact
        end
      end

      # Main request object for OpenRouter API
      class Request < ConfigObject
        # Required (either messages or prompt)
        attribute :messages, default: -> { [] }
        attribute :prompt, :string

        # Model specification
        attribute :model, :string

        # Response format
        attribute :response_format

        # Generation parameters
        attribute :stop # Can be string or array
        attribute :stream, :boolean, default: false
        attribute :max_tokens, :integer
        attribute :temperature, :float
        attribute :seed, :integer
        attribute :top_p, :float
        attribute :top_k, :integer
        attribute :frequency_penalty, :float
        attribute :presence_penalty, :float
        attribute :repetition_penalty, :float
        attribute :logit_bias, default: -> { {} }
        attribute :top_logprobs, :integer
        attribute :min_p, :float
        attribute :top_a, :float

        # Tool calling
        attribute :tools, default: -> { [] }
        attribute :tool_choice

        # Latency optimization
        attribute :prediction

        # OpenRouter-specific parameters
        attribute :transforms, default: -> { [] }
        attribute :models, default: -> { [] } # For fallback routing
        attribute :route, :string
        attribute :provider
        attribute :user, :string
        attribute :headers

        # Validations
        validate :validate_messages_or_prompt
        validates :max_tokens, numericality: { greater_than: 0 }, allow_nil: true
        validates :temperature, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 2 }, allow_nil: true
        validates :top_p, numericality: { greater_than: 0, less_than_or_equal_to: 1 }, allow_nil: true
        validates :top_k, numericality: { greater_than_or_equal_to: 1 }, allow_nil: true
        validates :frequency_penalty, numericality: { greater_than_or_equal_to: -2, less_than_or_equal_to: 2 }, allow_nil: true
        validates :presence_penalty, numericality: { greater_than_or_equal_to: -2, less_than_or_equal_to: 2 }, allow_nil: true
        validates :repetition_penalty, numericality: { greater_than: 0, less_than_or_equal_to: 2 }, allow_nil: true
        validates :min_p, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
        validates :top_a, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
        validates :route, inclusion: { in: %w[fallback] }, allow_nil: true

        accepts_attributes_for :response_format, ResponseFormat
        accepts_attributes_for :provider, ProviderPreferences
        accepts_attributes_for :prediction, Prediction
        accepts_attributes_for :tool_choice, ToolChoice
        accepts_attributes_for :headers, Header

        def build_parameters
          to_h.deep_transform_values do |value|
            case value
            when Array
              value.empty? ? nil : value
            else
              value
            end
          end.compact
        end

        # Setters with type coercion
        def messages=(value)
          if value.is_a?(Array)
            super(value.map do |msg|
              msg.is_a?(Message) ? msg : Message.new(msg)
            end)
          else
            super(value)
          end
        end

        def tools=(value)
          if value.is_a?(Array)
            super(value.map do |tool|
              tool.is_a?(Tool) ? tool : Tool.new(tool)
            end)
          else
            super(value)
          end
        end

        def response_format=(value)
          if value.is_a?(Hash) && !value.is_a?(ResponseFormat)
            super(ResponseFormat.new(value))
          else
            super(value)
          end
        end

        def provider=(value)
          if value.is_a?(Hash) && !value.is_a?(ProviderPreferences)
            super(ProviderPreferences.new(value))
          else
            super(value)
          end
        end

        def prediction=(value)
          if value.is_a?(Hash) && !value.is_a?(Prediction)
            super(Prediction.new(value))
          else
            super(value)
          end
        end

        def tool_choice=(value)
          super(ToolChoice.from_value(value))
        end

        def headers=(value)
          if value.is_a?(Hash) && !value.is_a?(Header)
            super(Header.new(value))
          else
            super(value)
          end
        end

        validate :validate_nested_objects

        private

        def validate_messages_or_prompt
          if messages.blank? && prompt.blank?
            errors.add(:base, "Either messages or prompt is required")
          end

          if messages.present? && prompt.present?
            errors.add(:base, "Cannot specify both messages and prompt")
          end
        end

        def validate_nested_objects
          # Validate messages
          if messages.present?
            messages.each_with_index do |message, index|
              next unless message.is_a?(Message)

              unless message.valid?
                message.errors.full_messages.each do |msg|
                  errors.add(:messages, "at index #{index}: #{msg}")
                end
              end
            end
          end

          # Validate tools
          if tools.present?
            tools.each_with_index do |tool, index|
              next unless tool.is_a?(Tool)

              unless tool.valid?
                tool.errors.full_messages.each do |msg|
                  errors.add(:tools, "at index #{index}: #{msg}")
                end
              end
            end
          end

          # Validate response_format
          if response_format.is_a?(ResponseFormat) && !response_format.valid?
            response_format.errors.full_messages.each do |msg|
              errors.add(:response_format, msg)
            end
          end

          # Validate provider
          if provider.is_a?(ProviderPreferences) && !provider.valid?
            provider.errors.full_messages.each do |msg|
              errors.add(:provider, msg)
            end
          end

          # Validate prediction
          if prediction.is_a?(Prediction) && !prediction.valid?
            prediction.errors.full_messages.each do |msg|
              errors.add(:prediction, msg)
            end
          end

          # Validate headers
          if headers.is_a?(Header) && !headers.valid?
            headers.errors.full_messages.each do |msg|
              errors.add(:headers, msg)
            end
          end
        end
      end
    end
  end
end
