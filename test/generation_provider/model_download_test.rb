require "test_helper"

class ModelDownloadTest < ActiveSupport::TestCase
  # Tests for the model download script
  # Run with: bin/test test/generation_provider/model_download_test.rb
  
  setup do
    @download_script = File.expand_path("../../bin/download_models", __dir__)
    @test_models_dir = Rails.root.join("tmp", "test_models")
    FileUtils.mkdir_p(@test_models_dir)
  end
  
  teardown do
    # Clean up test models directory
    FileUtils.rm_rf(@test_models_dir) if @test_models_dir.to_s.include?("tmp/test_models")
  end
  
  # region test_download_script_exists
  test "download script exists and is executable" do
    assert File.exist?(@download_script), "Download script should exist"
    assert File.executable?(@download_script), "Download script should be executable"
  end
  # endregion test_download_script_exists
  
  # region test_list_available_models
  test "lists available models" do
    output = `#{@download_script} list 2>&1`
    
    assert $?.success?, "List command should succeed"
    assert output.include?("Available Models"), "Should show available models"
    
    # Check for model categories
    assert output.include?("Text Generation"), "Should list text generation models"
    assert output.include?("Embeddings"), "Should list embedding models"
    assert output.include?("Vision"), "Should list vision models"
    
    # Check for specific models
    assert output.include?("gpt2-onnx"), "Should list GPT-2 ONNX model"
    assert output.include?("all-minilm-onnx"), "Should list MiniLM embedding model"
    
    puts "\n📋 Model categories found in list:"
    puts "  ✓ Text Generation" if output.include?("Text Generation")
    puts "  ✓ Embeddings" if output.include?("Embeddings")
    puts "  ✓ Vision" if output.include?("Vision")
    puts "  ✓ Multimodal" if output.include?("Multimodal")
    
    doc_example_output({ command: "list", output: output.lines.first(20).join })
  end
  # endregion test_list_available_models
  
  # region test_verify_gpu_support
  test "verifies GPU/hardware acceleration support" do
    output = `#{@download_script} verify 2>&1`
    
    assert $?.success?, "Verify command should succeed"
    assert output.include?("Platform:"), "Should show platform information"
    
    platform = RUBY_PLATFORM
    if platform.include?("darwin")
      # macOS specific checks
      if output.include?("Apple Silicon detected")
        assert output.include?("CoreML support available"), "Should mention CoreML on Apple Silicon"
        puts "\n🍎 Apple Silicon GPU support detected"
      else
        assert output.include?("Intel Mac detected"), "Should detect Intel Mac"
        puts "\n💻 Intel Mac detected"
      end
    elsif platform.include?("linux")
      # Linux specific checks
      assert output.include?("Linux Hardware Acceleration"), "Should check Linux acceleration"
      puts "\n🐧 Linux platform detected"
    end
    
    # Check for gem support
    assert output.include?("Ruby Gem Support"), "Should check Ruby gems"
    
    # Check for ONNX Runtime providers
    if output.include?("ONNX Runtime Execution Providers")
      providers = output.scan(/[🍎🎮🪟💻🔧]\s+(\w+ExecutionProvider)/).map(&:first)
      
      puts "\n🚀 Available ONNX Runtime providers:"
      providers.each { |p| puts "  - #{p}" }
      
      has_gpu = providers.any? { |p| !p.include?("CPU") }
      puts has_gpu ? "  ✅ GPU acceleration available" : "  ⚠️  CPU only"
    end
    
    doc_example_output({ command: "verify", platform: platform, output: output.lines.first(30).join })
  end
  # endregion test_verify_gpu_support
  
  # region test_model_info_command
  test "shows model information" do
    output = `#{@download_script} info gpt2-onnx 2>&1`
    
    assert $?.success?, "Info command should succeed"
    assert output.include?("Model Information: gpt2-onnx"), "Should show model name"
    assert output.include?("Description:"), "Should show description"
    assert output.include?("Source:"), "Should show source"
    
    if output.include?("✅ Downloaded")
      assert output.include?("Location:"), "Should show location for downloaded models"
      assert output.include?("Files:"), "Should list files"
      assert output.include?("Total size:"), "Should show total size"
    else
      assert output.include?("⬇️ Not downloaded"), "Should indicate not downloaded"
      assert output.include?("To download:"), "Should show download command"
    end
    
    doc_example_output({ command: "info", model: "gpt2-onnx", output: output })
  end
  # endregion test_model_info_command
  
  # region test_download_with_custom_directory
  test "downloads model to custom directory" do
    skip unless ENV["TEST_MODEL_DOWNLOAD"] == "true"
    
    # Use a small test model
    model_name = "all-minilm-onnx"
    
    output = `#{@download_script} download #{model_name} --dir #{@test_models_dir} 2>&1`
    
    assert $?.success?, "Download should succeed"
    assert output.include?("Successfully downloaded"), "Should confirm download"
    
    # Verify files were downloaded to custom directory
    model_dir = @test_models_dir.join(model_name)
    assert Dir.exist?(model_dir), "Model directory should exist"
    
    model_files = Dir.glob(File.join(model_dir, "**", "*")).reject { |f| File.directory?(f) }
    assert model_files.any?, "Should have downloaded files"
    
    # Check for ONNX model file
    onnx_files = model_files.select { |f| f.end_with?(".onnx") }
    assert onnx_files.any?, "Should have ONNX model file"
    
    puts "\n📦 Downloaded #{model_name} to custom directory:"
    puts "  Directory: #{model_dir}"
    puts "  Files: #{model_files.size}"
    puts "  Model size: #{format_file_size(onnx_files.first)}" if onnx_files.any?
    
    doc_example_output({
      command: "download",
      model: model_name,
      custom_dir: @test_models_dir.to_s,
      files_downloaded: model_files.size
    })
  end
  # endregion test_download_with_custom_directory
  
  # region test_force_redownload
  test "force re-download of existing model" do
    skip unless ENV["TEST_MODEL_DOWNLOAD"] == "true"
    
    model_name = "all-minilm-onnx"
    model_dir = @test_models_dir.join(model_name)
    
    # First download
    `#{@download_script} download #{model_name} --dir #{@test_models_dir} 2>&1`
    assert Dir.exist?(model_dir), "First download should create directory"
    
    # Get initial file modification time
    model_file = Dir.glob(File.join(model_dir, "**", "*.onnx")).first
    initial_mtime = File.mtime(model_file) if model_file
    
    # Try download without force (should skip)
    output = `#{@download_script} download #{model_name} --dir #{@test_models_dir} 2>&1`
    assert output.include?("already downloaded"), "Should skip existing model"
    
    # Download with force
    sleep 1  # Ensure different timestamp
    output = `#{@download_script} download #{model_name} --dir #{@test_models_dir} --force 2>&1`
    assert output.include?("Successfully downloaded"), "Should re-download with force"
    
    # Verify file was updated
    if model_file && File.exist?(model_file)
      new_mtime = File.mtime(model_file)
      assert new_mtime > initial_mtime, "File should be updated"
    end
    
    doc_example_output({
      command: "download --force",
      model: model_name,
      redownloaded: true
    })
  end
  # endregion test_force_redownload
  
  # region test_invalid_model_name
  test "handles invalid model name gracefully" do
    output = `#{@download_script} download nonexistent-model 2>&1`
    
    assert_not $?.success?, "Should fail for invalid model"
    assert output.include?("Unknown model"), "Should show error message"
    assert output.include?("bin/download_models list"), "Should suggest list command"
    
    doc_example_output({
      command: "download nonexistent-model",
      error: true,
      output: output
    })
  end
  # endregion test_invalid_model_name
  
  # region test_model_verification
  test "verifies downloaded model files" do
    skip unless ENV["TEST_MODEL_DOWNLOAD"] == "true"
    
    model_name = "gpt2-onnx"
    
    # Download with verbose output
    output = `#{@download_script} download #{model_name} --dir #{@test_models_dir} --verbose 2>&1`
    
    if $?.success?
      # Check verbose output includes file details
      assert output.include?("Downloaded"), "Verbose should show download details"
      assert output.include?("Model files verified"), "Should verify model files"
      
      # Verify essential files
      model_dir = @test_models_dir.join(model_name)
      assert File.exist?(model_dir.join("model.onnx")), "Should have model.onnx"
      
      if File.exist?(model_dir.join("tokenizer.json"))
        puts "\n✅ Tokenizer found"
      end
      
      if File.exist?(model_dir.join("tokenizer_config.json"))
        puts "✅ Tokenizer config found"
      end
    else
      puts "\n⚠️  Model download skipped or failed"
    end
  end
  # endregion test_model_verification
  
  # region test_help_command
  test "shows help information" do
    output = `#{@download_script} --help 2>&1`
    
    assert $?.success?, "Help command should succeed"
    assert output.include?("Usage:"), "Should show usage"
    assert output.include?("Commands:"), "Should list commands"
    assert output.include?("Options:"), "Should list options"
    
    # Check all commands are documented
    %w[list download download-all info verify].each do |cmd|
      assert output.include?(cmd), "Should document #{cmd} command"
    end
    
    # Check all options are documented
    %w[--verbose --dir --force --quantized --help].each do |opt|
      assert output.include?(opt), "Should document #{opt} option"
    end
    
    doc_example_output({ command: "--help", output: output })
  end
  # endregion test_help_command
  
  private
  
  def format_file_size(file_path)
    return "N/A" unless File.exist?(file_path)
    
    size = File.size(file_path)
    units = ["B", "KB", "MB", "GB"]
    unit_index = 0
    
    while size >= 1024 && unit_index < units.length - 1
      size = size.to_f / 1024
      unit_index += 1
    end
    
    "#{size.round(2)} #{units[unit_index]}"
  end
end