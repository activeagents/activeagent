class DataExtractionAgent < ApplicationAgent
  def describe_cat_image
    prompt(message: "Describe the cat in the image", image_data: CatImageService.fetch_base64_image)
  end
end