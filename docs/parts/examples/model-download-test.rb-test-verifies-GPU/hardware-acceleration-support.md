<!-- Generated from model_download_test.rb:88 -->
[activeagent/test/generation_provider/model_download_test.rb:88](vscode://file//Users/justinbowen/Documents/GitHub/claude-could/activeagent/test/generation_provider/model_download_test.rb:88)
<!-- Test: test-verifies-GPU/hardware-acceleration-support -->

```json
{
  "command": "verify",
  "platform": "arm64-darwin23",
  "output": "\n🔍 Verifying GPU/Hardware Acceleration Support\n\nPlatform: arm64-darwin23\n\n🍎 macOS Hardware Acceleration:\n  ✅ Apple Silicon detected: Apple M1 Pro\n  ✅ CoreML support available for ONNX Runtime\n  ✅ Metal Performance Shaders available\n\n  Recommended CoreML-optimized models:\n    ⬇️ gpt2-quantized-coreml\n\n📦 Ruby Gem Support:\n  ✅ onnxruntime (0.10.0)\n  ❌ transformers-ruby (not installed)\n     Install with: gem install transformers-ruby\n  ✅ informers (1.2.1)\n  ❌ ruby-openai (not installed)\n     Install with: gem install ruby-openai\n\n🚀 ONNX Runtime Execution Providers:\n\n  ❌ Error checking ONNX providers: undefined method `providers' for class OnnxRuntime::InferenceSession\n"
}
```