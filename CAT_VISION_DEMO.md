# Cat Vision Demo with ActiveAgent 🐱

This demo showcases multimodal AI capabilities using ONNX Runtime and Transformers providers with cat images from CATAAS (Cat as a Service).

## Setup

### 1. Install Required Gems

```bash
# For ONNX Runtime support
gem install onnxruntime
gem install informers

# For Transformers support
gem install transformers-ruby
```

### 2. Configure Rails

Add to your Gemfile:
```ruby
gem 'onnxruntime'
gem 'informers'
gem 'transformers-ruby'
```

## Demo Examples

### 1. Analyze Random Cat from CATAAS

```ruby
# Initialize the agent
agent = CatVisionAgent.new

# Analyze a random cat image
result = agent.analyze_random_cat
puts "Cat ID: #{result[:cat_id]}"
puts "Image URL: #{result[:image_url]}"
puts "CATAAS Tags: #{result[:cataas_tags].join(', ')}"
puts "Top Features Detected:"
result[:detected_features].each do |feature|
  puts "  - #{feature[:label]}: #{(feature[:score] * 100).round(1)}%"
end
```

### 2. Detect Cat Mood

```ruby
# Detect mood from a cat image
mood_result = agent.detect_cat_mood
puts "Detected Mood: #{mood_result[:detected_mood]}"
puts "Confidence: #{(mood_result[:confidence] * 100).round(1)}%"
puts "Recommendation: #{mood_result[:recommendation]}"
```

### 3. Identify Cat Breed

```ruby
# Identify breed
breed_result = agent.identify_breed_from_cataas
puts "Detected Breed: #{breed_result[:detected_breed]}"
puts "Top 3 Possible Breeds:"
breed_result[:top_3_breeds].each do |breed|
  puts "  - #{breed[:label]}: #{(breed[:score] * 100).round(1)}%"
end
puts "Breed Info: #{breed_result[:breed_info]}"
```

### 4. Cat Activity Detection

```ruby
# Detect what the cat is doing
activity_result = agent.detect_cat_activity
puts "Activity: #{activity_result[:detected_activity]}"
puts "Health Indicator: #{activity_result[:health_indicator]}"
```

### 5. Cat Appearance Analysis

```ruby
# Analyze cat's color and pattern
appearance = agent.analyze_cat_appearance
puts "Primary Color: #{appearance[:primary_color]}"
puts "Pattern: #{appearance[:pattern]}"
puts "Description: #{appearance[:appearance_description]}"
```

### 6. Meme Potential Scorer

```ruby
# Rate a cat's meme potential
meme_result = agent.rate_meme_potential
puts "Meme Type: #{meme_result[:meme_type]}"
puts "Meme Score: #{(meme_result[:meme_potential_score] * 100).round(1)}%"
puts "Suggested Caption: #{meme_result[:suggested_caption]}"
puts "Shareability: #{meme_result[:shareability]}"
```

### 7. Multi-Cat Scene Analysis

```ruby
# Analyze the scene around the cat
scene_result = agent.analyze_cat_scene
puts "Scene Type: #{scene_result[:scene_type]}"
puts "Objects Detected:"
scene_result[:objects_detected].each do |obj|
  puts "  - #{obj[:object]} (#{(obj[:confidence] * 100).round(1)}%)"
end
puts "Description: #{scene_result[:scene_description]}"
```

### 8. Find Similar Cats

```ruby
# Find cats similar to a reference cat
similarity_result = agent.find_similar_cats_from_cataas
puts "Reference Cat: #{similarity_result[:reference_cat][:id]}"
puts "Most Similar Cat:"
most_similar = similarity_result[:most_similar]
puts "  ID: #{most_similar[:cat_id]}"
puts "  Similarity: #{(most_similar[:similarity_score] * 100).round(1)}%"
puts "  Tags: #{most_similar[:tags].join(', ')}"
```

### 9. Batch Analysis

```ruby
# Analyze multiple cats at once
collection = agent.analyze_cat_collection
puts "Analyzed #{collection[:total_analyzed]} cats"
puts "Common Tags:"
collection[:common_tags].each do |tag, count|
  puts "  #{tag}: #{count} occurrences"
end
puts "Mood Distribution:"
collection[:mood_distribution].each do |mood, percentage|
  puts "  #{mood}: #{percentage}%"
end
```

## Configuration Options

### Using Different Models

```ruby
# Use Google's SigLIP for better understanding
agent = CatVisionAgent.new
agent.class.generation_provider = {
  "service" => "OnnxRuntime",
  "model_type" => "multimodal",
  "model" => "google/siglip-base-patch16-224",
  "task" => "zero-shot-image-classification",
  "model_source" => "huggingface"
}

# Use M-CLIP for multilingual support
agent.class.generation_provider = {
  "service" => "OnnxRuntime",
  "model_type" => "multimodal",
  "model" => "M-CLIP/XLM-Roberta-Large-Vit-B-32",
  "task" => "image-text-matching",
  "model_source" => "huggingface"
}
```

### Device Selection

```ruby
# Use Apple Silicon GPU (M1/M2/M3)
config = {
  "service" => "Transformers",
  "device" => "mps",  # Metal Performance Shaders
  # ... other config
}

# Use NVIDIA GPU
config = {
  "service" => "Transformers",
  "device" => "cuda",
  # ... other config
}

# Use CPU (default)
config = {
  "service" => "OnnxRuntime",
  "device" => "cpu",
  # ... other config
}
```

## Performance Tips

### For M1 MacBook Pro Demo

1. Use MPS acceleration:
```ruby
{
  "service" => "Transformers",
  "device" => "mps",
  "model" => "distilbert-base-uncased"  # Smaller model for speed
}
```

2. Pre-download models:
```ruby
# In an initializer
Rails.application.config.after_initialize do
  ActiveAgent::ModelPreloader.preload_models([
    :clip_model,
    :vision_model
  ])
end
```

### For Jetson Nano Demo

1. Use ONNX Runtime with CUDA:
```ruby
{
  "service" => "OnnxRuntime",
  "device" => "cuda",
  "model" => "microsoft/resnet-18"  # Lighter model
}
```

2. Reduce image size:
```ruby
# Use smaller images from CATAAS
image_url = "https://cataas.com/cat?width=128&json=true"
```

## Interactive Rails Console Demo

```ruby
# Start Rails console
rails console

# Load the agent
agent = CatVisionAgent.new

# Quick demo sequence
puts "🐱 Cat Vision AI Demo"
puts "=" * 50

# 1. Get a random cat
cat = agent.analyze_random_cat
puts "\n📸 Analyzing cat: #{cat[:image_url]}"
puts "Tags: #{cat[:cataas_tags].join(', ')}"

# 2. Detect mood
mood = agent.detect_cat_mood
puts "\n😸 Mood: #{mood[:detected_mood]}"

# 3. Identify breed
breed = agent.identify_breed_from_cataas
puts "\n🐈 Breed: #{breed[:detected_breed]}"

# 4. Rate meme potential
meme = agent.rate_meme_potential
puts "\n😄 Meme Score: #{(meme[:meme_potential_score] * 100).round}%"
puts "Caption: #{meme[:suggested_caption]}"

puts "\n" + "=" * 50
puts "Demo complete! 🎉"
```

## Web Interface Demo

Create a simple controller to demonstrate in a web interface:

```ruby
# app/controllers/cat_vision_controller.rb
class CatVisionController < ApplicationController
  def index
    @agent = CatVisionAgent.new
  end
  
  def analyze
    @agent = CatVisionAgent.new
    @result = @agent.analyze_random_cat
    render json: @result
  end
  
  def mood
    @agent = CatVisionAgent.new
    @result = @agent.detect_cat_mood
    render json: @result
  end
  
  def breed
    @agent = CatVisionAgent.new
    @result = @agent.identify_breed_from_cataas
    render json: @result
  end
end
```

## Troubleshooting

### Model Download Issues
- Models are cached in `tmp/models/` by default
- First run may take time to download models
- Check internet connection for HuggingFace access

### Memory Issues
- Use smaller models for limited memory
- Process one image at a time
- Clear cache between analyses if needed

### Performance Issues
- Ensure correct device is selected
- Use quantized models when available
- Pre-download and cache models

## Next Steps

1. **Custom Training**: Fine-tune models on specific cat breeds
2. **Real-time Processing**: Add webcam support for live cat detection
3. **Cat Health Monitoring**: Extend to detect health issues
4. **Multi-cat Tracking**: Track multiple cats in video
5. **Cat Behavior Analysis**: Analyze play patterns and activities

## Resources

- [CATAAS API](https://cataas.com/) - Cat as a Service
- [HuggingFace Models](https://huggingface.co/models) - Pre-trained models
- [ONNX Runtime](https://onnxruntime.ai/) - Cross-platform inference
- [Transformers](https://github.com/huggingface/transformers) - State-of-the-art models

Enjoy your cat-powered AI adventures! 🐱🤖