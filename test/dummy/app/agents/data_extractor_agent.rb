class DataExtractorAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o-mini",
    instructions: "Extract structured data from the provided text. Return the data in the exact JSON format specified by the schema."

  def extract_resume_data
    # Extract structured resume data with JSON schema loaded from view
    prompt(message: params[:text], json_schema: true)
  end

  def extract_contact_info
    # Extract just contact information with a simpler schema loaded from view
    prompt(message: params[:text], json_schema: true)
  end

  def extract_skills
    # Extract skills with categorization loaded from view
    prompt(message: params[:text], json_schema: true)
  end
end
