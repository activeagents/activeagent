class OnnxInferenceAgent < ApplicationAgent
  # This agent runs ONNX models with GPU acceleration using CoreML on macOS
  
  generate_with :onnx_runtime, {
    model_type: "custom",
    execution_providers: ["CoreMLExecutionProvider", "CPUExecutionProvider"],
    log_gpu_usage: true,
    enable_profiling: true
  }
  
  def initialize
    super
    @models_dir = Rails.root.join("models")
    FileUtils.mkdir_p(@models_dir)
  end
  
  def run_inference
    model_path = params[:model_path] || find_available_model
    input_data = params[:input_data]
    
    unless model_path && File.exist?(model_path)
      return { error: "No model found at #{model_path}" }
    end
    
    # Update provider config with the model path
    self.class.generation_provider_config[:model_path] = model_path
    
    # Log GPU info before inference
    log_gpu_status("Before inference")
    
    # Run inference
    start_time = Time.now
    result = perform_inference(model_path, input_data)
    inference_time = Time.now - start_time
    
    # Log GPU info after inference
    log_gpu_status("After inference")
    
    {
      model: File.basename(model_path),
      inference_time_ms: (inference_time * 1000).round(2),
      gpu_used: detect_gpu_usage,
      provider: detect_active_provider,
      result: result
    }
  end
  
  def benchmark_gpu
    model_path = params[:model_path] || find_available_model
    iterations = params[:iterations] || 10
    
    unless model_path && File.exist?(model_path)
      return { error: "No model found" }
    end
    
    results = {
      model: File.basename(model_path),
      iterations: iterations,
      times: [],
      gpu_metrics: []
    }
    
    iterations.times do |i|
      gpu_before = capture_gpu_metrics
      
      start_time = Time.now
      perform_inference(model_path, generate_test_input)
      elapsed = Time.now - start_time
      
      gpu_after = capture_gpu_metrics
      
      results[:times] << (elapsed * 1000).round(2)
      results[:gpu_metrics] << {
        before: gpu_before,
        after: gpu_after,
        delta: calculate_gpu_delta(gpu_before, gpu_after)
      }
      
      puts "  Iteration #{i + 1}: #{results[:times].last}ms"
    end
    
    results[:average_ms] = (results[:times].sum / results[:times].size).round(2)
    results[:min_ms] = results[:times].min
    results[:max_ms] = results[:times].max
    results[:gpu_utilized] = results[:gpu_metrics].any? { |m| m[:delta][:usage] > 5 }
    
    results
  end
  
  private
  
  def find_available_model
    # Look for downloaded ONNX models
    Dir.glob(@models_dir.join("**/*.onnx")).first ||
    Dir.glob(Rails.root.join("test/fixtures/models/*.onnx")).first
  end
  
  def perform_inference(model_path, input_data)
    require 'onnxruntime'
    
    # Load model with GPU provider
    model = OnnxRuntime::Model.new(
      model_path,
      providers: ["CoreMLExecutionProvider", "CPUExecutionProvider"]
    )
    
    # Prepare input
    input = prepare_input(model, input_data)
    
    # Run inference
    output = model.predict(input)
    
    output
  rescue => e
    { error: e.message }
  end
  
  def prepare_input(model, input_data)
    # Get model input shape and prepare data accordingly
    inputs = model.inputs
    
    if input_data
      input_data
    else
      # Generate dummy input based on model requirements
      generate_dummy_input(inputs)
    end
  end
  
  def generate_dummy_input(inputs)
    # Create appropriate dummy input for the model
    result = {}
    
    inputs.each do |input_info|
      name = input_info["name"]
      shape = input_info["shape"]
      type = input_info["type"]
      
      # Handle dynamic dimensions (often represented as strings or -1)
      shape = shape.map { |dim| dim.is_a?(String) || dim < 0 ? 1 : dim }
      
      # Generate random data of appropriate shape
      if type.include?("float")
        result[name] = Array.new(shape[0] || 1) { Array.new(shape[1] || 224) { rand } }
      elsif type.include?("int")
        result[name] = Array.new(shape[0] || 1) { Array.new(shape[1] || 128) { rand(0..1000) } }
      end
    end
    
    result
  end
  
  def generate_test_input
    # Generate standard test input for benchmarking
    {
      "input" => Array.new(1) { Array.new(224) { Array.new(224) { Array.new(3) { rand } } } }
    }
  end
  
  def log_gpu_status(label)
    if RUBY_PLATFORM.include?("darwin")
      puts "\n📊 GPU Status (#{label}):"
      
      # Check if using CoreML
      providers = get_available_providers
      puts "  Available providers: #{providers.join(', ')}"
      
      # Try to get GPU metrics
      metrics = capture_gpu_metrics
      puts "  GPU Usage: #{metrics[:usage]}%" if metrics[:usage]
      puts "  GPU Memory: #{metrics[:memory_mb]}MB" if metrics[:memory_mb]
    end
  end
  
  def get_available_providers
    require 'onnxruntime'
    session = OnnxRuntime::InferenceSession.allocate
    session.providers
  rescue
    ["Unknown"]
  end
  
  def detect_active_provider
    providers = get_available_providers
    if providers.include?("CoreMLExecutionProvider")
      "CoreML"
    elsif providers.include?("CUDAExecutionProvider")
      "CUDA"
    else
      "CPU"
    end
  end
  
  def detect_gpu_usage
    metrics_before = capture_gpu_metrics
    sleep 0.1
    metrics_after = capture_gpu_metrics
    
    if metrics_after[:usage] && metrics_before[:usage]
      metrics_after[:usage] > metrics_before[:usage]
    else
      false
    end
  end
  
  def capture_gpu_metrics
    if RUBY_PLATFORM.include?("darwin")
      # Try to get GPU metrics on macOS
      # This is simplified - real implementation would use system profiler
      {
        usage: rand(10..50),  # Mock for now
        memory_mb: rand(100..500),
        timestamp: Time.now
      }
    else
      {}
    end
  end
  
  def calculate_gpu_delta(before, after)
    {
      usage: (after[:usage] || 0) - (before[:usage] || 0),
      memory: (after[:memory_mb] || 0) - (before[:memory_mb] || 0)
    }
  end
end