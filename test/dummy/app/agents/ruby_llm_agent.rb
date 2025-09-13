class RubyLLMAgent < ApplicationAgent
  generate_with :ruby_llm, model: "gpt-4o-mini", temperature: 0.7

  def chat
    @message = params[:message]
    prompt
  end

  def ask_with_provider
    @message = params[:message]
    @provider = params[:provider] || "openai"
    prompt options: { provider: @provider }
  end

  def structured_response
    @question = params[:question]
    
    output_schema = {
      type: "object",
      properties: {
        answer: { type: "string", description: "The answer to the question" },
        confidence: { type: "number", description: "Confidence level from 0 to 1" },
        reasoning: { type: "string", description: "Brief explanation of the answer" }
      },
      required: ["answer", "confidence", "reasoning"]
    }
    
    prompt output_schema: output_schema
  end

  def generate_embedding
    @text = params[:text]
    # Note: For embeddings, we would typically use the embed method
    # but this is just an example of how it would be used
    prompt
  end
end