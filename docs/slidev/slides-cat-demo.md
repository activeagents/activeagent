---
theme: default
title: Cat Vision AI with ActiveAgent
layout: cover
background: https://cataas.com/cat
---

# Cat Vision AI 🐱
## Local Multimodal Models with ActiveAgent

Running CLIP, SigLIP, and Vision Transformers locally in Rails

---
layout: two-cols
---

# The Code

```ruby
# Using CATAAS for cat images
agent = CatVisionAgent.new

# Analyze mood with CLIP
result = agent.detect_cat_mood

puts result[:detected_mood]
# => "playful cat"

puts result[:confidence]
# => 0.92
```

::right::

<RailsDemo 
  url="http://localhost:3000/cat_vision/mood"
  title="Live Cat Mood Detection"
  height="400px"
/>

---
layout: iframe-right
url: http://localhost:3000/cat_vision
---

# Live Demo Features

- 🎯 **Breed Detection** - Identify cat breeds
- 😸 **Mood Analysis** - Detect cat emotions  
- 🎨 **Appearance** - Colors and patterns
- 📸 **Scene Analysis** - Understand context
- 🎭 **Meme Scoring** - Rate meme potential

::right::
<!-- Live app appears here -->

---
layout: two-cols
---

# Configuration

```ruby
# For M1 MacBook (MPS)
{
  "service" => "Transformers",
  "device" => "mps",
  "model" => "openai/clip-vit-base"
}

# For Jetson Nano (CUDA)
{
  "service" => "OnnxRuntime", 
  "device" => "cuda",
  "model" => "microsoft/resnet-18"
}
```

::right::

<div class="flex flex-col gap-4 p-4">
  <img src="http://localhost:3000/cat_vision/random.jpg" class="rounded-lg shadow-lg" />
  <div class="bg-gray-100 dark:bg-gray-800 rounded p-4">
    <pre>Processing on: Apple M1 Pro
Model: CLIP ViT-B/32
Inference: ~120ms</pre>
  </div>
</div>

---
layout: center
class: text-center
---

# Interactive Demo

<iframe 
  src="http://localhost:3000/cat_vision/interactive" 
  class="w-full h-96 rounded-lg shadow-2xl"
/>

Click to analyze different cats in real-time!

---
layout: custom
---

# Side-by-Side Comparison

<div class="grid grid-cols-2 gap-4 h-full">
  <iframe 
    src="http://localhost:3000/cat_vision?model=clip"
    class="w-full h-full rounded-lg"
    title="CLIP Model"
  />
  <iframe 
    src="http://localhost:3000/cat_vision?model=siglip"
    class="w-full h-full rounded-lg"
    title="SigLIP Model"
  />
</div>

<div class="absolute bottom-4 left-0 right-0 text-center">
  <span class="text-sm">CLIP vs SigLIP Performance Comparison</span>
</div>

---

# Terminal Output Integration

<div class="grid grid-cols-2 gap-4">
  <div>
    <h3>Rails Console</h3>
    <iframe 
      src="http://localhost:3000/terminal"
      class="w-full h-64 rounded bg-black"
    />
  </div>
  <div>
    <h3>Live Response</h3>
    <iframe 
      src="http://localhost:3000/cat_vision/api/analyze"
      class="w-full h-64 rounded"
    />
  </div>
</div>

---
layout: iframe
url: http://localhost:3000/cat_vision/dashboard
---