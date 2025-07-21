class DataExtractorAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o-mini",
    instructions: "Extract structured data from the provided text. Return the data in the exact JSON format specified by the schema."

  def extract_resume_data
    # Extract structured resume data with JSON schema
    json_schema = {
      type: "object",
      properties: {
        personal_info: {
          type: "object",
          properties: {
            name: {type: "string"},
            title: {type: "string"},
            email: {type: "string"},
            phone: {type: "string"},
            location: {type: "string"}
          },
          required: ["name"]
        },
        experience: {
          type: "array",
          items: {
            type: "object",
            properties: {
              company: {type: "string"},
              position: {type: "string"},
              duration: {type: "string"},
              achievements: {
                type: "array",
                items: {type: "string"}
              }
            },
            required: ["company", "position"]
          }
        },
        education: {
          type: "object",
          properties: {
            degree: {type: "string"},
            institution: {type: "string"},
            duration: {type: "string"},
            gpa: {type: "string"}
          }
        },
        skills: {
          type: "object",
          properties: {
            programming_languages: {
              type: "array",
              items: {type: "string"}
            },
            frameworks: {
              type: "array",
              items: {type: "string"}
            },
            databases: {
              type: "array",
              items: {type: "string"}
            },
            tools: {
              type: "array",
              items: {type: "string"}
            }
          }
        }
      },
      required: ["personal_info"]
    }

    context = prompt(message: params[:text])
    context.options[:json_schema] = json_schema
    context
  end

  def extract_contact_info
    # Extract just contact information with a simpler schema
    json_schema = {
      type: "object",
      properties: {
        name: {type: "string"},
        email: {type: "string"},
        phone: {type: "string"},
        location: {type: "string"}
      },
      required: ["name"]
    }

    context = prompt(message: params[:text])
    context.options[:json_schema] = json_schema
    context
  end

  def extract_skills
    # Extract skills with categorization
    json_schema = {
      type: "object",
      properties: {
        technical_skills: {
          type: "array",
          items: {type: "string"}
        },
        soft_skills: {
          type: "array",
          items: {type: "string"}
        },
        certifications: {
          type: "array",
          items: {type: "string"}
        }
      }
    }

    context = prompt(message: params[:text])
    context.options[:json_schema] = json_schema
    context
  end
end
