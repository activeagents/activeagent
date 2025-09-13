require "test_helper"

class GpuInferenceTest < ActiveSupport::TestCase
  # Test GPU inference using downloaded ONNX models
  
  setup do
    @models_dir = Rails.root.join("models", "test")
    FileUtils.mkdir_p(@models_dir)
  end
  
  # region test_download_and_run_onnx_model
  test "downloads ONNX model and runs inference with GPU" do
    # First, download a small ONNX model using MCP
    VCR.use_cassette("download_small_onnx_model") do
      download_agent = ModelDownloadAgent.new
      
      # Search for small ONNX models
      search_result = download_agent.with(
        query: "mobilenet onnx",
        library: "onnxruntime"
      ).search_onnx_models
      
      assert search_result.present?, "Should find ONNX models"
      
      # Download the smallest model found
      if search_result.is_a?(Hash) && search_result[:models].present?
        smallest_model = search_result[:models].min_by { |m| m[:size] || Float::INFINITY }
        
        download_result = download_agent.with(
          model_id: smallest_model[:id],
          save_path: @models_dir
        ).download_model
        
        assert_equal "success", download_result[:status]
        @model_path = download_result[:path]
      else
        # Fallback to a known small model
        @model_path = download_small_test_model
      end
    end
    
    # Now run inference with GPU acceleration
    inference_agent = OnnxInferenceAgent.new
    
    result = inference_agent.with(
      model_path: @model_path
    ).run_inference
    
    assert result[:inference_time_ms].present?, "Should measure inference time"
    assert result[:provider].present?, "Should detect execution provider"
    
    puts "\n🚀 GPU Inference Results:"
    puts "  Model: #{result[:model]}"
    puts "  Inference time: #{result[:inference_time_ms]}ms"
    puts "  Provider: #{result[:provider]}"
    puts "  GPU used: #{result[:gpu_used] ? '✅ Yes' : '❌ No'}"
    
    # Verify GPU was used on supported platforms
    if RUBY_PLATFORM.include?("darwin") && has_apple_silicon?
      assert_equal "CoreML", result[:provider], "Should use CoreML on Apple Silicon"
    end
    
    doc_example_output(result)
  end
  # endregion test_download_and_run_onnx_model
  
  # region test_benchmark_gpu_performance
  test "benchmarks GPU performance with ONNX model" do
    model_path = ensure_test_model_available
    
    inference_agent = OnnxInferenceAgent.new
    
    benchmark_result = inference_agent.with(
      model_path: model_path,
      iterations: 5
    ).benchmark_gpu
    
    assert benchmark_result[:average_ms].present?, "Should calculate average inference time"
    assert benchmark_result[:gpu_metrics].present?, "Should capture GPU metrics"
    
    puts "\n📊 GPU Benchmark Results:"
    puts "  Model: #{benchmark_result[:model]}"
    puts "  Iterations: #{benchmark_result[:iterations]}"
    puts "  Average: #{benchmark_result[:average_ms]}ms"
    puts "  Min: #{benchmark_result[:min_ms]}ms"
    puts "  Max: #{benchmark_result[:max_ms]}ms"
    puts "  GPU utilized: #{benchmark_result[:gpu_utilized] ? '✅ Yes' : '❌ No'}"
    
    # Check if performance is reasonable
    assert benchmark_result[:average_ms] < 1000, "Inference should be under 1 second"
    
    doc_example_output(benchmark_result)
  end
  # endregion test_benchmark_gpu_performance
  
  # region test_compare_cpu_vs_gpu
  test "compares CPU vs GPU inference performance" do
    model_path = ensure_test_model_available
    
    # Run with CPU only
    cpu_agent = OnnxInferenceAgent.new
    cpu_agent.class.generation_provider_config[:execution_providers] = ["CPUExecutionProvider"]
    
    cpu_result = cpu_agent.with(
      model_path: model_path,
      iterations: 3
    ).benchmark_gpu
    
    # Run with GPU (CoreML on macOS)
    gpu_agent = OnnxInferenceAgent.new
    gpu_agent.class.generation_provider_config[:execution_providers] = ["CoreMLExecutionProvider", "CPUExecutionProvider"]
    
    gpu_result = gpu_agent.with(
      model_path: model_path,
      iterations: 3
    ).benchmark_gpu
    
    speedup = cpu_result[:average_ms] / gpu_result[:average_ms]
    
    puts "\n⚡ CPU vs GPU Performance:"
    puts "  CPU average: #{cpu_result[:average_ms]}ms"
    puts "  GPU average: #{gpu_result[:average_ms]}ms"
    puts "  Speedup: #{speedup.round(2)}x"
    
    # GPU should be faster (or at least not slower)
    assert gpu_result[:average_ms] <= cpu_result[:average_ms] * 1.1,
           "GPU should not be significantly slower than CPU"
    
    doc_example_output({
      cpu: cpu_result,
      gpu: gpu_result,
      speedup: speedup
    })
  end
  # endregion test_compare_cpu_vs_gpu
  
  private
  
  def download_small_test_model
    # Download a small MobileNet ONNX model for testing
    require 'open-uri'
    
    model_url = "https://github.com/onnx/models/raw/main/validated/vision/classification/mobilenet/model/mobilenetv2-7.onnx"
    model_path = @models_dir.join("mobilenetv2-7.onnx")
    
    unless File.exist?(model_path)
      puts "⬇️  Downloading MobileNetV2 ONNX model (13MB)..."
      URI.open(model_url) do |remote_file|
        File.open(model_path, 'wb') do |local_file|
          local_file.write(remote_file.read)
        end
      end
      puts "✅ Downloaded to #{model_path}"
    end
    
    model_path.to_s
  end
  
  def ensure_test_model_available
    # Ensure we have at least one model for testing
    model_path = Dir.glob(@models_dir.join("*.onnx")).first ||
                 Dir.glob(Rails.root.join("test/fixtures/models/*.onnx")).first
    
    if model_path.nil? || !File.exist?(model_path.to_s)
      model_path = download_small_test_model
    end
    
    model_path.to_s
  end
  
  def has_apple_silicon?
    cpu_info = `sysctl -n machdep.cpu.brand_string 2>/dev/null`.strip
    cpu_info.include?("Apple")
  rescue
    false
  end
end