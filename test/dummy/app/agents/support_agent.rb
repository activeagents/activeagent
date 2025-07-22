class SupportAgent < ApplicationAgent
  layout "agent"
  generate_with :openai, model: "gpt-4o-mini", instructions: "You're a support agent. Your job is to help users with their questions.", stream: false

  def get_cat_image
    prompt(content_type: "image_url", context_id: params[:context_id]) do |format|
      format.text { render plain: CatImageService.fetch_base64_image }
      format.json
    end
  end
end
