class SupportAgent < ApplicationAgent
  layout "agent"
  generate_with :openai, model: "gpt-4o-mini", instructions: "You're a support agent. Your job is to help users with their questions."

  def get_cat_image
    prompt(content_type: "image_url", context_id: params[:context_id]) do |format|
      format.text { render plain: CatImageService.fetch_image_url }
    end
  end
end
