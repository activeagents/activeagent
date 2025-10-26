class DataExtractionAgent < ApplicationAgent
  before_action :set_multimodal_content, only: [ :parse_content ]

  def parse_content
    prompt_args = {
      message: params[:message] || "Parse the content of the file or image",
      image_data: @image_data,
      file_data: @file_data
    }

    if params[:response_format]
      prompt_args[:response_format] = params[:response_format]
    elsif params[:output_schema]
      # Support legacy output_schema parameter
      prompt_args[:response_format] = {
        type: "json_schema",
        json_schema: params[:output_schema]
      }
    end

    prompt(**prompt_args)
  end

  def describe_cat_image
    prompt(
      message: "Describe the cat in the image",
      image_data: CatImageService.fetch_base64_image
      )
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
