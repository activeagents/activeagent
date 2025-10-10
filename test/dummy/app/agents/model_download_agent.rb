class ModelDownloadAgent < ApplicationAgent
  # This agent uses Hugging Face MCP to download ONNX models for local inference
  
  def download_onnx_model
    @model_name = params[:model_name] || "Xenova/all-MiniLM-L6-v2"
    @save_path = params[:save_path] || Rails.root.join("models", @model_name.gsub("/", "_"))
    
    prompt(
      mcp_servers: ["hugging-face"],
      actions: [:search_model, :download_model, :save_file]
    )
  end
  
  def search_model
    # Use Hugging Face MCP to search for ONNX models
    {
      tool: "mcp__hugging-face__model_search",
      parameters: {
        query: params[:query] || "onnx",
        library: "onnxruntime",
        limit: 5
      }
    }
  end
  
  def download_model
    # Download model files from Hugging Face
    model_id = params[:model_id] || @model_name
    
    {
      tool: "mcp__hugging-face__hub_repo_details",
      parameters: {
        repo_ids: [model_id],
        repo_type: "model"
      }
    }
  end
  
  def save_file
    # Save the downloaded model to local filesystem
    require 'fileutils'
    require 'open-uri'
    
    url = params[:url]
    filename = params[:filename] || "model.onnx"
    
    FileUtils.mkdir_p(@save_path)
    file_path = File.join(@save_path, filename)
    
    URI.open(url) do |remote_file|
      File.open(file_path, 'wb') do |local_file|
        local_file.write(remote_file.read)
      end
    end
    
    {
      status: "success",
      path: file_path,
      size: File.size(file_path)
    }
  rescue => e
    {
      status: "error",
      message: e.message
    }
  end
  
  def list_available_onnx_models
    # List popular ONNX models suitable for testing
    prompt(
      message: "List small ONNX models under 50MB suitable for testing GPU inference",
      mcp_servers: ["hugging-face"],
      actions: [:search_onnx_models]
    )
  end
  
  def search_onnx_models
    {
      tool: "mcp__hugging-face__model_search",
      parameters: {
        query: "onnx mini small tiny",
        library: "onnxruntime",
        sort: "downloads",
        limit: 10
      }
    }
  end
end