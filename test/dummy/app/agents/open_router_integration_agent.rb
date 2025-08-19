class OpenRouterIntegrationAgent < ApplicationAgent
  generate_with :open_router,
    model: "openai/gpt-4o",
    fallback_models: [ "anthropic/claude-sonnet-4" ],
    enable_fallbacks: true,
    track_costs: true

  def analyze_image
    @image_url = params[:image_url]
    @image_path = params[:image_path]

    # Create an ActiveAgent::ActionPrompt::Message with multimodal content
    message = ActiveAgent::ActionPrompt::Message.new(
      content: build_image_message,
      role: :user
    )

    # Pass the multimodal message directly to prompt
    prompt(
      message: message,
      output_schema: image_analysis_schema
    )
  end

  def extract_receipt_data
    @image_url = params[:image_url]
    @image_path = params[:image_path]

    # Create an ActiveAgent::ActionPrompt::Message with multimodal content
    message = ActiveAgent::ActionPrompt::Message.new(
      content: build_receipt_message,
      role: :user
    )

    # Pass the multimodal message directly to prompt
    prompt(
      message: message,
      output_schema: receipt_schema
    )
  end

  def process_long_text
    @text = params[:text]

    prompt(
      message: "Summarize the following text in 3 bullet points:\n\n#{@text}",
      options: { transforms: [ "middle-out" ] }
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
        models: [ "openai/gpt-3.5-turbo-0301", "openai/gpt-3.5-turbo", "openai/gpt-4o-mini" ],
        route: "fallback"
      }
    )
  end

  def analyze_content
    @content = params[:content]
    prompt(message: @content)
  end

  def analyze_pdf
    @pdf_url = params[:pdf_url]
    @pdf_data = params[:pdf_data]

    # Allow users to specify their preferred PDF processing engine
    # Options: 'mistral-ocr' ($2/1000 pages), 'pdf-text' (free), 'native' (input tokens)
    pdf_engine = params[:pdf_engine] || "pdf-text"  # Default to free option

    # Build the proper plugin format for OpenRouter PDF processing
    pdf_plugin = {
      id: "file-parser",
      pdf: {
        engine: pdf_engine
      }
    }

    # Allow disabling plugins entirely for models with built-in support
    options = params[:skip_plugin] ? { plugins: [] } : { plugins: [ pdf_plugin ] }
    
    if @pdf_url
      prompt(
        message: [
          { type: "text", text: params[:prompt_text] || "Analyze this PDF document and provide a summary." },
          { type: "file", file: { file_name: 'test.pdf', file_data: @pdf_url } }
        ],
        options: options,
        output_schema: params[:output_schema]
      )
    elsif @pdf_data
      prompt(
        message: [
          { type: "text", text: params[:prompt_text] || "Analyze this PDF document and provide a summary." },
          { type: "file", file: { file_name: 'test.pdf', file_data: "data:application/pdf;base64,#{@pdf_data}" } }
        ],
        options: options,
        output_schema: params[:output_schema]
      )
    else
      prompt(message: "No PDF provided")
    end
  end

  private

  def build_image_message
    if @image_url
      [
        { type: "text", text: "Analyze this image and describe what you see. Return your response as a JSON object with description, objects array, scene_type, and primary_colors." },
        { type: "image_url", image_url: { url: @image_url } }
      ]
    elsif @image_path
      image_data = Base64.strict_encode64(File.read(@image_path))
      mime_type = "image/jpeg"  # Simplified for testing
      [
        { type: "text", text: "Analyze this image and describe what you see. Return your response as a JSON object with description, objects array, scene_type, and primary_colors." },
        { type: "image_url", image_url: { url: "data:#{mime_type};base64,#{image_data}" } }
      ]
    else
      "No image provided"
    end
  end

  def build_receipt_message
    if @image_url
      [
        { type: "text", text: "Extract the receipt information from this image." },
        { type: "image_url", image_url: { url: @image_url } }
      ]
    elsif @image_path
      image_data = Base64.strict_encode64(File.read(@image_path))
      mime_type = "image/png"  # For receipt images
      [
        { type: "text", text: "Extract the receipt information from this image." },
        { type: "image_url", image_url: { url: "data:#{mime_type};base64,#{image_data}" } }
      ]
    else
      "No receipt image provided"
    end
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
              required: [ "name", "position", "color" ],
              additionalProperties: false
            }
          },
          scene_type: {
            type: "string",
            enum: [ "indoor", "outdoor", "abstract", "document", "photo", "illustration" ]
          },
          primary_colors: {
            type: "array",
            items: { type: "string" }
          }
        },
        required: [ "description", "objects", "scene_type", "primary_colors" ],
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
            required: [ "name", "address" ],
            additionalProperties: false
          },
          date: { type: "string" },
          total: {
            type: "object",
            properties: {
              amount: { type: "number" },
              currency: { type: "string" }
            },
            required: [ "amount", "currency" ],
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
              required: [ "name", "price", "quantity" ],
              additionalProperties: false
            }
          },
          tax: { type: "number" },
          subtotal: { type: "number" }
        },
        required: [ "merchant", "total", "items", "date", "tax", "subtotal" ],
        additionalProperties: false
      }
    }
  end
end
