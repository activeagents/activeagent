class DataExtractorAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o-mini",
    instructions: "Extract structured data from the provided text. Return the data in the exact JSON format specified by the schema."

  def extract_resume_data
    # Extract structured resume data with schema loaded from view
    prompt(message: params[:text], structured_output: { template: "extract_resume_data_schema" })
  end

  def extract_contact_info
    # Extract just contact information with a simpler schema loaded from view
    prompt(message: params[:text], structured_output: { template: "extract_contact_info_schema" })
  end

  def extract_skills
    # Extract skills with categorization loaded from view
    prompt(message: params[:text], structured_output: { template: "extract_skills_schema" })
  end

  def analyze_document
    # This action can serve both as:
    # 1. A tool that other agents can call (tool schema in analyze_document.json.jbuilder)
    # 2. An action with structured output (output schema in analyze_document_output.json.jbuilder)

    if params[:use_structured_output]
      # Use structured output for analysis results
      prompt(
        message: "Analyze this document: #{params[:text]}",
        structured_output: { template: "analyze_document_output" }
      )
    else
      # Regular response that could be called by other agents as a tool
      prompt(message: "Analyze this document: #{params[:text]}")
    end
  end

  def encode_pdf
    File.open(params[:file_path], "rb") do |file|
      
    end
  end
end
