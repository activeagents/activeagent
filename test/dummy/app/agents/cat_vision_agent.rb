# frozen_string_literal: true

require 'net/http'
require 'json'
require 'open-uri'

# CatVisionAgent - Multimodal AI agent for all things cat! 🐱
# Uses CATAAS (Cat as a Service) for random cat images
# Demonstrates image classification, text-image similarity, and visual Q&A
class CatVisionAgent < ApplicationAgent
  CATAAS_BASE_URL = "https://cataas.com"
  
  # Example 1: Analyze random cat from CATAAS
  def analyze_random_cat
    # Fetch random cat with metadata
    cat_data = fetch_random_cat_with_metadata
    
    # Configure multimodal model for analysis
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "multimodal",
      "model" => "openai/clip-vit-base-patch32",
      "task" => "zero-shot-image-classification",
      "model_source" => "huggingface",
      "cache_dir" => Rails.root.join("tmp", "models", "vision").to_s
    }
    
    # Generate smart labels based on CATAAS tags if available
    labels = generate_labels_from_metadata(cat_data)
    
    # Download and analyze the cat image
    image_url = "#{CATAAS_BASE_URL}/cat/#{cat_data['_id']}"
    
    result = prompt message: {
      image: image_url,
      labels: labels
    }
    
    {
      cat_id: cat_data['_id'],
      cataas_tags: cat_data['tags'] || [],
      image_url: image_url,
      analysis: result.message.content,
      detected_features: extract_top_features(result, 3),
      metadata: cat_data
    }
  end
  
  # Example 2: Batch analyze multiple CATAAS cats
  def analyze_cat_collection
    num_cats = params[:count] || 5
    cats = []
    
    num_cats.times do
      cat_data = fetch_random_cat_with_metadata
      cats << analyze_single_cat(cat_data)
    end
    
    {
      total_analyzed: cats.length,
      cats: cats,
      common_tags: find_common_tags(cats),
      mood_distribution: calculate_mood_distribution(cats)
    }
  end
  
  # Example 3: Find cats by specific CATAAS tags
  def find_cats_by_tag
    tag = params[:tag] || "cute"
    
    # Fetch cat with specific tag from CATAAS
    cat_data = fetch_cat_by_tag(tag)
    
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "multimodal",
      "model" => "google/siglip-base-patch16-224",
      "task" => "zero-shot-image-classification",
      "model_source" => "huggingface"
    }
    
    # Create detailed labels for tag verification
    labels = [
      "#{tag} cat",
      "not #{tag} cat",
      "very #{tag} cat",
      "slightly #{tag} cat",
      "extremely #{tag} cat"
    ]
    
    image_url = "#{CATAAS_BASE_URL}/cat/#{tag}?json=true"
    
    result = prompt message: {
      image: image_url,
      labels: labels
    }
    
    {
      requested_tag: tag,
      image_url: image_url,
      tag_accuracy: calculate_tag_accuracy(result, tag),
      analysis: result.message.content
    }
  end
  
  # Example 4: Cat mood detection using CATAAS images
  def detect_cat_mood
    # Fetch random cat
    cat_data = fetch_random_cat_with_metadata
    
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "multimodal",
      "model" => "openai/clip-vit-base-patch32",
      "task" => "zero-shot-image-classification",
      "model_source" => "huggingface"
    }
    
    # Comprehensive mood labels
    mood_labels = [
      "happy cat",
      "sleepy cat",
      "angry cat",
      "playful cat",
      "hungry cat",
      "curious cat",
      "scared cat",
      "relaxed cat",
      "mischievous cat",
      "content cat",
      "alert cat",
      "bored cat"
    ]
    
    image_url = "#{CATAAS_BASE_URL}/cat/#{cat_data['_id']}"
    
    result = prompt message: {
      image: image_url,
      labels: mood_labels
    }
    
    detected_mood = extract_top_label(result)
    mood_confidence = extract_confidence(result)
    
    {
      cat_id: cat_data['_id'],
      image_url: image_url,
      detected_mood: detected_mood,
      confidence: mood_confidence,
      cataas_tags: cat_data['tags'] || [],
      mood_matches_tags: mood_matches_tags?(detected_mood, cat_data['tags']),
      recommendation: mood_based_recommendation(detected_mood)
    }
  end
  
  # Example 5: Cat breed identification from CATAAS
  def identify_breed_from_cataas
    cat_data = fetch_random_cat_with_metadata
    
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "multimodal",
      "model" => "microsoft/resnet-50",
      "task" => "image-classification",
      "model_source" => "huggingface"
    }
    
    # Common cat breeds
    breed_labels = [
      "tabby cat",
      "siamese cat",
      "persian cat",
      "maine coon",
      "british shorthair",
      "ragdoll cat",
      "bengal cat",
      "scottish fold",
      "russian blue",
      "sphynx cat",
      "mixed breed cat",
      "domestic shorthair",
      "domestic longhair"
    ]
    
    image_url = "#{CATAAS_BASE_URL}/cat/#{cat_data['_id']}"
    
    result = prompt message: {
      image: image_url,
      labels: breed_labels
    }
    
    {
      cat_id: cat_data['_id'],
      image_url: image_url,
      detected_breed: extract_top_label(result),
      confidence: extract_confidence(result),
      top_3_breeds: extract_top_features(result, 3),
      cataas_tags: cat_data['tags'] || [],
      breed_info: breed_information(extract_top_label(result))
    }
  end
  
  # Example 6: Cat activity detection from CATAAS
  def detect_cat_activity
    cat_data = fetch_random_cat_with_metadata
    
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "multimodal",
      "model" => "google/siglip-base-patch16-224",
      "task" => "zero-shot-image-classification",
      "model_source" => "huggingface"
    }
    
    activity_labels = [
      "cat sleeping",
      "cat eating",
      "cat playing",
      "cat grooming",
      "cat sitting",
      "cat standing",
      "cat stretching",
      "cat jumping",
      "cat hunting",
      "cat yawning",
      "cat meowing",
      "cat cuddling"
    ]
    
    image_url = "#{CATAAS_BASE_URL}/cat/#{cat_data['_id']}"
    
    result = prompt message: {
      image: image_url,
      labels: activity_labels
    }
    
    detected_activity = extract_top_label(result)
    
    {
      cat_id: cat_data['_id'],
      image_url: image_url,
      detected_activity: detected_activity,
      confidence: extract_confidence(result),
      cataas_tags: cat_data['tags'] || [],
      activity_matches_tags: activity_matches_tags?(detected_activity, cat_data['tags']),
      health_indicator: activity_health_indicator(detected_activity)
    }
  end
  
  # Example 7: Cat color and pattern analysis
  def analyze_cat_appearance
    cat_data = fetch_random_cat_with_metadata
    
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "multimodal",
      "model" => "openai/clip-vit-base-patch32",
      "task" => "zero-shot-image-classification",
      "model_source" => "huggingface"
    }
    
    # Analyze colors
    color_labels = [
      "orange cat",
      "black cat",
      "white cat",
      "gray cat",
      "brown cat",
      "calico cat",
      "tortoiseshell cat",
      "tuxedo cat",
      "tabby cat",
      "ginger cat"
    ]
    
    # Analyze patterns
    pattern_labels = [
      "striped cat",
      "spotted cat",
      "solid color cat",
      "patched cat",
      "marbled cat"
    ]
    
    image_url = "#{CATAAS_BASE_URL}/cat/#{cat_data['_id']}"
    
    color_result = prompt message: {
      image: image_url,
      labels: color_labels
    }
    
    pattern_result = prompt message: {
      image: image_url,
      labels: pattern_labels
    }
    
    {
      cat_id: cat_data['_id'],
      image_url: image_url,
      primary_color: extract_top_label(color_result),
      color_confidence: extract_confidence(color_result),
      pattern: extract_top_label(pattern_result),
      pattern_confidence: extract_confidence(pattern_result),
      cataas_tags: cat_data['tags'] || [],
      appearance_description: generate_appearance_description(
        extract_top_label(color_result),
        extract_top_label(pattern_result)
      )
    }
  end
  
  # Example 8: Cat meme potential scorer
  def rate_meme_potential
    cat_data = fetch_random_cat_with_metadata
    
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "multimodal",
      "model" => "openai/clip-vit-base-patch32",
      "task" => "zero-shot-image-classification",
      "model_source" => "huggingface"
    }
    
    meme_labels = [
      "funny cat",
      "derpy cat",
      "majestic cat",
      "grumpy cat",
      "surprised cat",
      "judgmental cat",
      "confused cat",
      "dramatic cat",
      "sassy cat",
      "normal cat"
    ]
    
    image_url = "#{CATAAS_BASE_URL}/cat/#{cat_data['_id']}"
    
    result = prompt message: {
      image: image_url,
      labels: meme_labels
    }
    
    meme_type = extract_top_label(result)
    meme_score = calculate_meme_score(result)
    
    {
      cat_id: cat_data['_id'],
      image_url: image_url,
      meme_type: meme_type,
      meme_potential_score: meme_score,
      suggested_caption: generate_meme_caption(meme_type),
      cataas_tags: cat_data['tags'] || [],
      shareability: meme_score > 0.7 ? "High" : meme_score > 0.4 ? "Medium" : "Low"
    }
  end
  
  # Example 9: Multi-cat scene analysis
  def analyze_cat_scene
    cat_data = fetch_random_cat_with_metadata
    
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "multimodal",
      "model" => "facebook/detr-resnet-50",
      "task" => "object-detection",
      "model_source" => "huggingface"
    }
    
    image_url = "#{CATAAS_BASE_URL}/cat/#{cat_data['_id']}"
    
    # First detect objects
    detection_result = prompt message: { image: image_url }
    
    # Then analyze the scene context
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "multimodal",
      "model" => "openai/clip-vit-base-patch32",
      "task" => "zero-shot-image-classification",
      "model_source" => "huggingface"
    }
    
    scene_labels = [
      "indoor scene",
      "outdoor scene",
      "living room",
      "bedroom",
      "kitchen",
      "garden",
      "street",
      "windowsill",
      "couch",
      "floor"
    ]
    
    scene_result = prompt message: {
      image: image_url,
      labels: scene_labels
    }
    
    {
      cat_id: cat_data['_id'],
      image_url: image_url,
      objects_detected: parse_detections(detection_result),
      scene_type: extract_top_label(scene_result),
      scene_confidence: extract_confidence(scene_result),
      cataas_tags: cat_data['tags'] || [],
      scene_description: generate_scene_description(detection_result, scene_result)
    }
  end
  
  # Example 10: Cat similarity search using CATAAS
  def find_similar_cats_from_cataas
    # Get reference cat
    reference_cat = fetch_random_cat_with_metadata
    reference_url = "#{CATAAS_BASE_URL}/cat/#{reference_cat['_id']}"
    
    # Get comparison cats
    num_comparisons = params[:num_comparisons] || 5
    comparison_cats = []
    
    num_comparisons.times do
      cat_data = fetch_random_cat_with_metadata
      comparison_cats << {
        data: cat_data,
        url: "#{CATAAS_BASE_URL}/cat/#{cat_data['_id']}"
      }
    end
    
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "multimodal",
      "model" => "openai/clip-vit-base-patch32",
      "task" => "image-text-matching",
      "model_source" => "huggingface"
    }
    
    # Generate embedding for reference cat
    reference_embedding = generate_image_embedding(reference_url)
    
    # Compare with other cats
    similarities = comparison_cats.map do |cat|
      cat_embedding = generate_image_embedding(cat[:url])
      similarity = cosine_similarity(reference_embedding, cat_embedding)
      
      {
        cat_id: cat[:data]['_id'],
        image_url: cat[:url],
        similarity_score: similarity,
        tags: cat[:data]['tags'] || [],
        is_similar: similarity > 0.7
      }
    end
    
    {
      reference_cat: {
        id: reference_cat['_id'],
        url: reference_url,
        tags: reference_cat['tags'] || []
      },
      similar_cats: similarities.sort_by { |s| -s[:similarity_score] },
      most_similar: similarities.max_by { |s| s[:similarity_score] },
      average_similarity: similarities.map { |s| s[:similarity_score] }.sum / similarities.length
    }
  end
  
  private
  
  def fetch_random_cat_with_metadata
    uri = URI("#{CATAAS_BASE_URL}/cat?json=true")
    response = Net::HTTP.get_response(uri)
    JSON.parse(response.body)
  rescue => e
    Rails.logger.error "Failed to fetch cat from CATAAS: #{e.message}"
    { '_id' => 'fallback', 'tags' => [] }
  end
  
  def fetch_cat_by_tag(tag)
    uri = URI("#{CATAAS_BASE_URL}/cat/#{tag}?json=true")
    response = Net::HTTP.get_response(uri)
    JSON.parse(response.body)
  rescue => e
    Rails.logger.error "Failed to fetch cat with tag #{tag}: #{e.message}"
    fetch_random_cat_with_metadata
  end
  
  def analyze_single_cat(cat_data)
    self.class.generation_provider = {
      "service" => "OnnxRuntime",
      "model_type" => "multimodal",
      "model" => "openai/clip-vit-base-patch32",
      "task" => "zero-shot-image-classification",
      "model_source" => "huggingface"
    }
    
    labels = generate_labels_from_metadata(cat_data)
    image_url = "#{CATAAS_BASE_URL}/cat/#{cat_data['_id']}"
    
    result = prompt message: {
      image: image_url,
      labels: labels
    }
    
    {
      id: cat_data['_id'],
      url: image_url,
      tags: cat_data['tags'] || [],
      analysis: extract_top_label(result),
      confidence: extract_confidence(result)
    }
  end
  
  def generate_labels_from_metadata(cat_data)
    base_labels = ["cute cat", "funny cat", "sleepy cat", "playful cat", "serious cat"]
    
    # Add labels based on CATAAS tags if present
    if cat_data['tags'] && !cat_data['tags'].empty?
      tag_labels = cat_data['tags'].map { |tag| "#{tag} cat" }
      base_labels + tag_labels
    else
      base_labels + ["adorable cat", "beautiful cat", "fluffy cat", "small cat", "big cat"]
    end
  end
  
  def extract_top_features(result, count = 3)
    return [] unless result.message.content.is_a?(Array)
    
    result.message.content
      .sort_by { |item| -(item[:score] || item["score"] || 0) }
      .first(count)
      .map { |item| { label: item[:label] || item["label"], score: item[:score] || item["score"] } }
  end
  
  def extract_top_label(result)
    if result.message.content.is_a?(Array)
      result.message.content.max_by { |item| item[:score] || item["score"] || 0 }[:label] rescue "unknown"
    else
      "unknown"
    end
  end
  
  def extract_confidence(result)
    if result.message.content.is_a?(Array)
      result.message.content.max_by { |item| item[:score] || item["score"] || 0 }[:score] rescue 0.0
    else
      0.0
    end
  end
  
  def calculate_tag_accuracy(result, tag)
    return 0.0 unless result.message.content.is_a?(Array)
    
    tag_related_scores = result.message.content.select do |item|
      label = item[:label] || item["label"]
      label.include?(tag)
    end
    
    return 0.0 if tag_related_scores.empty?
    
    tag_related_scores.map { |item| item[:score] || item["score"] || 0 }.max
  end
  
  def mood_matches_tags?(mood, tags)
    return false if tags.nil? || tags.empty?
    
    mood_keywords = mood.downcase.split.reject { |w| w == "cat" }
    tags.any? { |tag| mood_keywords.any? { |keyword| tag.downcase.include?(keyword) } }
  end
  
  def activity_matches_tags?(activity, tags)
    return false if tags.nil? || tags.empty?
    
    activity_keywords = activity.downcase.split.reject { |w| w == "cat" }
    tags.any? { |tag| activity_keywords.any? { |keyword| tag.downcase.include?(keyword) } }
  end
  
  def mood_based_recommendation(mood)
    recommendations = {
      "happy cat" => "Your cat is content! Keep up the good care.",
      "sleepy cat" => "Let your cat rest in a quiet, comfortable spot.",
      "angry cat" => "Give your cat some space and check for stressors.",
      "playful cat" => "Great time for interactive play with toys!",
      "hungry cat" => "Check if it's feeding time or offer a healthy treat.",
      "curious cat" => "Provide safe exploration opportunities.",
      "scared cat" => "Create a safe, quiet environment and speak softly.",
      "relaxed cat" => "Your cat feels safe and comfortable.",
      "mischievous cat" => "Cat-proof your valuables and provide enrichment!",
      "content cat" => "Perfect balance - your cat is happy.",
      "alert cat" => "Your cat is engaged - good time for training.",
      "bored cat" => "Add new toys or activities for stimulation."
    }
    
    recommendations[mood] || "Observe your cat and provide appropriate care."
  end
  
  def breed_information(breed)
    breed_info = {
      "tabby cat" => "Common and friendly, known for their 'M' marking on forehead",
      "siamese cat" => "Vocal and social, with distinctive blue eyes",
      "persian cat" => "Long-haired and calm, requires regular grooming",
      "maine coon" => "Large and gentle giants, very friendly",
      "british shorthair" => "Calm and easygoing, with dense coat",
      "ragdoll cat" => "Docile and affectionate, goes limp when picked up",
      "bengal cat" => "Active and playful, with wild appearance",
      "scottish fold" => "Sweet-tempered with distinctive folded ears",
      "russian blue" => "Quiet and shy, with silvery-blue coat",
      "sphynx cat" => "Hairless and warm, very social",
      "mixed breed cat" => "Unique combination of traits, often healthier",
      "domestic shorthair" => "Most common cat type, varied personalities",
      "domestic longhair" => "Fluffy and varied, needs regular grooming"
    }
    
    breed_info[breed] || "A wonderful feline companion"
  end
  
  def activity_health_indicator(activity)
    indicators = {
      "cat sleeping" => "Normal - cats sleep 12-16 hours daily",
      "cat eating" => "Good - regular eating is healthy",
      "cat playing" => "Excellent - indicates good health and energy",
      "cat grooming" => "Normal - cats groom 30-50% of waking time",
      "cat sitting" => "Normal - observing environment",
      "cat standing" => "Alert and active",
      "cat stretching" => "Good - maintains flexibility",
      "cat jumping" => "Great - shows strength and agility",
      "cat hunting" => "Natural predator behavior",
      "cat yawning" => "Relaxed or waking up",
      "cat meowing" => "Communicating - check for needs",
      "cat cuddling" => "Affectionate and bonded"
    }
    
    indicators[activity] || "Normal cat behavior"
  end
  
  def generate_appearance_description(color, pattern)
    "A beautiful #{pattern.downcase.gsub(' cat', '')} #{color.downcase}"
  end
  
  def calculate_meme_score(result)
    return 0.0 unless result.message.content.is_a?(Array)
    
    meme_worthy = ["funny cat", "derpy cat", "grumpy cat", "surprised cat", "dramatic cat", "sassy cat"]
    
    meme_scores = result.message.content.select do |item|
      label = item[:label] || item["label"]
      meme_worthy.include?(label)
    end
    
    return 0.0 if meme_scores.empty?
    
    meme_scores.map { |item| item[:score] || item["score"] || 0 }.max
  end
  
  def generate_meme_caption(meme_type)
    captions = {
      "funny cat" => "When you realize it's only Tuesday",
      "derpy cat" => "Me trying to adult",
      "majestic cat" => "Bow before your feline overlord",
      "grumpy cat" => "No.",
      "surprised cat" => "When the treats bag crinkles",
      "judgmental cat" => "I see you didn't fill my bowl to the top",
      "confused cat" => "Instructions unclear, knocked over plant",
      "dramatic cat" => "The audacity!",
      "sassy cat" => "I do what I want",
      "normal cat" => "Just cat things"
    }
    
    captions[meme_type] || "Cat."
  end
  
  def parse_detections(detection_result)
    return [] unless detection_result.message.content.is_a?(Array)
    
    detection_result.message.content.map do |detection|
      {
        object: detection[:label] || detection["label"],
        confidence: detection[:score] || detection["score"],
        location: detection[:bbox] || detection["bbox"] || []
      }
    end
  end
  
  def generate_scene_description(detection_result, scene_result)
    scene = extract_top_label(scene_result)
    objects = parse_detections(detection_result)
    
    cat_count = objects.count { |obj| obj[:object]&.downcase&.include?("cat") }
    other_objects = objects.reject { |obj| obj[:object]&.downcase&.include?("cat") }
                           .map { |obj| obj[:object] }
                           .first(3)
    
    description = "#{cat_count} cat(s) in #{scene.downcase}"
    description += " with #{other_objects.join(', ')}" unless other_objects.empty?
    description
  end
  
  def find_common_tags(cats)
    all_tags = cats.flat_map { |cat| cat[:tags] || [] }
    tag_counts = all_tags.tally
    tag_counts.sort_by { |_, count| -count }.first(5).to_h
  end
  
  def calculate_mood_distribution(cats)
    moods = cats.map { |cat| cat[:analysis] || "unknown" }
    mood_counts = moods.tally
    total = moods.length.to_f
    
    mood_counts.transform_values { |count| (count / total * 100).round(1) }
  end
  
  def generate_image_embedding(image_url)
    response = prompt message: { image: image_url }
    response.message.content
  end
  
  def cosine_similarity(vec1, vec2)
    return 0.0 unless vec1.is_a?(Array) && vec2.is_a?(Array)
    return 0.0 if vec1.size != vec2.size
    
    dot_product = vec1.zip(vec2).map { |a, b| (a || 0) * (b || 0) }.sum
    magnitude1 = Math.sqrt(vec1.map { |a| (a || 0)**2 }.sum)
    magnitude2 = Math.sqrt(vec2.map { |a| (a || 0)**2 }.sum)
    
    return 0.0 if magnitude1 == 0 || magnitude2 == 0
    
    dot_product / (magnitude1 * magnitude2)
  end
end