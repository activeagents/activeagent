class OpenRouterIntegrationAgent < ApplicationAgent
  generate_with :open_router, 
    model: "openai/gpt-4o-mini",
    fallback_models: ["openai/gpt-3.5-turbo"],
    enable_fallbacks: true,
    track_costs: true

  def analyze_image
    @image_url = params[:image_url]
    @image_path = params[:image_path]
    
    prompt(
      message: build_image_message,
      output_schema: image_analysis_schema
    )
  end

  def extract_receipt_data
    @image_url = params[:image_url]
    
    prompt(
      message: build_receipt_message,
      output_schema: receipt_schema
    )
  end

  def process_long_text
    @text = params[:text]
    
    prompt(
      message: "Summarize the following text in 3 bullet points:\n\n#{@text}",
      options: { transforms: ["middle-out"] }
    )
  end

  def test_fallback
    # Use a model with small context and provide text that might exceed it
    # This should trigger fallback to a model with larger context
    long_context = "Please summarize this: " + ("The quick brown fox jumps over the lazy dog. " * 50)
    
    prompt(
      message: long_context + "\n\nNow, what is 2+2? Answer with just the number.",
      options: { 
        # Try to use a model with limited context first
        models: ["openai/gpt-3.5-turbo-0301", "openai/gpt-3.5-turbo", "openai/gpt-4o-mini"],
        route: "fallback"
      }
    )
  end

  private

  def build_image_message
    if @image_url
      [
        { type: "text", text: "Analyze this image and describe what you see." },
        { type: "image_url", image_url: { url: @image_url } }
      ]
    elsif @image_path
      image_data = Base64.strict_encode64(File.read(@image_path))
      mime_type = "image/jpeg"  # Simplified for testing
      [
        { type: "text", text: "Analyze this image and describe what you see." },
        { type: "image_url", image_url: { url: "data:#{mime_type};base64,#{image_data}" } }
      ]
    else
      "No image provided"
    end
  end

  def build_receipt_message
    [
      { type: "text", text: "Extract the receipt information from this image. Include merchant name, total amount, date, and line items." },
      { type: "image_url", image_url: { url: @image_url } }
    ]
  end

  def image_analysis_schema
    {
      name: "image_analysis",
      strict: true,
      schema: {
        type: "object",
        properties: {
          description: { 
            type: "string",
            description: "A detailed description of the image"
          },
          objects: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string" },
                position: { type: "string" },
                color: { type: "string" }
              },
              required: ["name"],
              additionalProperties: false
            }
          },
          scene_type: {
            type: "string",
            enum: ["indoor", "outdoor", "abstract", "document", "photo", "illustration"]
          },
          primary_colors: {
            type: "array",
            items: { type: "string" }
          }
        },
        required: ["description", "objects", "scene_type"],
        additionalProperties: false
      }
    }
  end

  def receipt_schema
    {
      name: "receipt_data",
      strict: true,
      schema: {
        type: "object",
        properties: {
          merchant: {
            type: "object",
            properties: {
              name: { type: "string" },
              address: { type: "string" }
            },
            required: ["name"],
            additionalProperties: false
          },
          date: { type: "string" },
          total: {
            type: "object",
            properties: {
              amount: { type: "number" },
              currency: { type: "string" }
            },
            required: ["amount"],
            additionalProperties: false
          },
          items: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string" },
                quantity: { type: "integer" },
                price: { type: "number" }
              },
              required: ["name", "price"],
              additionalProperties: false
            }
          },
          tax: { type: "number" },
          subtotal: { type: "number" }
        },
        required: ["merchant", "total"],
        additionalProperties: false
      }
    }
  end
end