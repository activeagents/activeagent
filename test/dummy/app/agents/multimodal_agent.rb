# Example agent demonstrating multimodal capabilities with built-in tools
# This agent uses the Responses API to access advanced tools
class MultimodalAgent < ApplicationAgent
  # Use default temperature for Responses API compatibility
  generate_with :openai, model: "gpt-4o", temperature: nil

  # Generate an image based on a description
  def create_image
    @description = params[:description]
    @size = params[:size] || "1024x1024"
    @quality = params[:quality] || "high"

    prompt(
      message: "Generate an image: #{@description}",
      options: {
        use_responses_api: true,
        tools: [
          {
            type: "image_generation",
            size: @size,
            quality: @quality,
            format: "png"
          }
        ]
      }
    )
  end

  # Research a topic and create an infographic
  def create_infographic
    @topic = params[:topic]
    @style = params[:style] || "modern"

    prompt(
      message: build_infographic_prompt,
      options: {
        use_responses_api: true,
        tools: [
          { type: "web_search_preview", search_context_size: "high" },
          {
            type: "image_generation",
            size: "1024x1536",  # Tall format for infographic
            quality: "high",
            background: "opaque"
          }
        ]
      }
    )
  end

  # Analyze an image and search for related information
  def analyze_and_research
    @image_data = params[:image_data]  # Base64 encoded image
    @question = params[:question]

    prompt(
      message: @question,
      image_data: @image_data,
      options: {
        use_responses_api: true,
        tools: [
          { type: "web_search_preview" }
        ]
      }
    )
  end

  # Edit an existing image with AI
  def edit_image
    @original_image = params[:original_image]
    @instructions = params[:instructions]

    prompt(
      message: @instructions,
      image_data: @original_image,
      options: {
        use_responses_api: true,
        tools: [
          {
            type: "image_generation",
            partial_images: 2  # Show progress during generation
          }
        ]
      }
    )
  end

  private

  def build_infographic_prompt
    <<~PROMPT
      Create a #{@style} infographic about #{@topic}.

      First, research the topic to gather accurate, up-to-date information.
      Then generate a visually appealing infographic that includes:
      - Key statistics and facts
      - Clear visual hierarchy
      - #{@style} design aesthetic
      - Easy-to-read layout

      Make it informative and visually engaging.
    PROMPT
  end
end
