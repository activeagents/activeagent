class DataExtractionAgent < ActiveAgent::Base
  layout "agent"

  generate_with :openai, 
                model: "gpt-4o", 
                instructions: "You are a data extraction agent. Extract and analyze information from various input formats including text, images, and documents."

  def extract_from_text(text_content)
    prompt message: text_content, text_content: text_content
  end

  def extract_from_image(image_data)
    multipart_content = [
      { "type" => "input_text", "text" => "Extract all text and information from this image" },
      { "type" => "input_image", "image_url" => image_data }
    ]
    
    prompt message: { content: multipart_content, role: :user }
  end

  def extract_from_document(file_id, question = nil)
    question_text = question || "Extract all key information from this document"
    
    multipart_content = [
      { "type" => "input_text", "text" => question_text },
      { "type" => "input_file", "file_id" => file_id }
    ]
    
    prompt message: { content: multipart_content, role: :user }
  end

  def extract_from_multipart(text_part, image_part = nil, file_part = nil)
    content = []
    
    # Add text part
    content << { "type" => "input_text", "text" => text_part }
    
    # Add image part if provided
    if image_part
      content << { "type" => "input_image", "image_url" => image_part }
    end
    
    # Add file part if provided  
    if file_part
      content << { "type" => "input_file", "file_id" => file_part }
    end
    
    prompt message: { content: content, role: :user }
  end
end
