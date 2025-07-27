class DataExtractionAgent < ApplicationAgent
  before_action :set_multimodal_content, only: [ :parse_content ]

  def describe_cat_image
    prompt(message: "Describe the cat in the image", image_data: CatImageService.fetch_base64_image)
  end

  def parse_content
    prompt(message: params[:message] || "Parse the content of the file or image",
      image_data: @image_data,
      file_data: @file_data,
      output_schema: params[:output_schema])
  end

  private
  def set_multimodal_content
    if params[:file_path].present?
      @file_data ||= "data:application/pdf;base64,#{Base64.encode64(File.read(params[:file_path]))}"
    elsif params[:image_path].present?
      @image_data ||= "data:image/jpeg;base64,#{Base64.encode64(File.read(params[:image_path]))}"
    end
  end
end
