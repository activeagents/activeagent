# frozen_string_literal: true

class StructuredDataAgent < ApplicationAgent
  # Use GPT-4o-mini for structured output support
  generate_with :openai,
    model: "gpt-4o-mini"

  # Extract structured data from unstructured content
  def extract_structured
    @content = params[:content]
    @schema = params[:schema]
    @instructions = params[:instructions]

    # Ensure schema has required fields for OpenAI
    if @schema.is_a?(Hash) && !@schema.key?(:name)
      @schema = {
        name: "extracted_data",
        strict: true,
        schema: @schema
      }
    end

    prompt(
      output_schema: @schema,
      content_type: :json
    )
  end

  # Parse content and extract specific fields
  def parse_page_data
    @html_content = params[:html_content]
    @text_content = params[:text_content]
    @url = params[:url]

    # Define a schema for common web page data
    page_schema = {
      name: "webpage_data",
      strict: true,
      schema: {
        type: "object",
        properties: {
          title: { type: "string", description: "Page title" },
          main_heading: { type: "string", description: "Main H1 heading" },
          description: { type: "string", description: "Page description or summary" },
          headings: {
            type: "array",
            items: { type: "string" },
            description: "All headings on the page"
          },
          links: {
            type: "array",
            items: {
              type: "object",
              properties: {
                text: { type: "string" },
                href: { type: "string" }
              },
              required: ["text", "href"],
              additionalProperties: false
            },
            description: "All links on the page"
          },
          images: {
            type: "array",
            items: {
              type: "object",
              properties: {
                alt: { type: "string" },
                src: { type: "string" }
              },
              required: ["src"],
              additionalProperties: false
            },
            description: "All images on the page"
          },
          main_content: { type: "string", description: "Main content text" },
          metadata: {
            type: "object",
            properties: {
              url: { type: "string" },
              word_count: { type: "integer" },
              has_forms: { type: "boolean" },
              has_tables: { type: "boolean" }
            },
            additionalProperties: false
          }
        },
        required: ["title", "main_content", "metadata"],
        additionalProperties: false
      }
    }

    prompt(
      output_schema: page_schema,
      content_type: :json
    )
  end

  # Extract form data structure
  def extract_form_schema
    @form_html = params[:form_html]
    @form_context = params[:form_context]

    form_schema = {
      name: "form_structure",
      strict: true,
      schema: {
        type: "object",
        properties: {
          form_name: { type: "string" },
          action: { type: "string" },
          method: { type: "string" },
          fields: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string" },
                type: { type: "string" },
                label: { type: "string" },
                required: { type: "boolean" },
                placeholder: { type: "string" },
                options: {
                  type: "array",
                  items: { type: "string" }
                }
              },
              required: ["name", "type"],
              additionalProperties: false
            }
          },
          submit_button: {
            type: "object",
            properties: {
              text: { type: "string" },
              name: { type: "string" }
            },
            additionalProperties: false
          }
        },
        required: ["fields"],
        additionalProperties: false
      }
    }

    prompt(
      output_schema: form_schema,
      content_type: :json
    )
  end

  # Extract product information from e-commerce pages
  def extract_product_data
    @page_content = params[:page_content]
    @url = params[:url]

    product_schema = {
      name: "product_info",
      strict: true,
      schema: {
        type: "object",
        properties: {
          name: { type: "string" },
          price: { type: "number" },
          currency: { type: "string" },
          description: { type: "string" },
          availability: { type: "string" },
          rating: { type: "number" },
          reviews_count: { type: "integer" },
          images: {
            type: "array",
            items: { type: "string" }
          },
          specifications: {
            type: "object",
            additionalProperties: { type: "string" }
          },
          categories: {
            type: "array",
            items: { type: "string" }
          }
        },
        required: ["name", "price"],
        additionalProperties: false
      }
    }

    prompt(
      output_schema: product_schema,
      content_type: :json
    )
  end

  # Compare multiple data sources
  def compare_data
    @data_sources = params[:data_sources]
    @comparison_schema = params[:comparison_schema]

    comparison_result_schema = {
      name: "comparison_result",
      strict: true,
      schema: {
        type: "object",
        properties: {
          summary: { type: "string" },
          differences: {
            type: "array",
            items: {
              type: "object",
              properties: {
                field: { type: "string" },
                source1_value: { type: "string" },
                source2_value: { type: "string" },
                significance: { type: "string" }
              },
              required: ["field"],
              additionalProperties: false
            }
          },
          similarities: {
            type: "array",
            items: {
              type: "object",
              properties: {
                field: { type: "string" },
                value: { type: "string" }
              },
              required: ["field", "value"],
              additionalProperties: false
            }
          },
          recommendation: { type: "string" }
        },
        required: ["summary", "differences", "similarities"],
        additionalProperties: false
      }
    }

    prompt(
      output_schema: @comparison_schema || comparison_result_schema,
      content_type: :json
    )
  end
end