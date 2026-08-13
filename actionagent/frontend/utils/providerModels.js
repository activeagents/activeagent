// Model options for the agent builder/editor. The server is the source of
// truth (/api/provider_models): curated current lists for hosted providers,
// live lookups for Ollama (the account's configured host) and OpenRouter.
// These fallbacks only cover a failed fetch.
export const FALLBACK_PROVIDER_MODELS = {
  openai: ['gpt-5.1', 'gpt-5', 'gpt-5-mini', 'gpt-5-nano'],
  anthropic: ['claude-opus-5', 'claude-fable-5', 'claude-sonnet-5', 'claude-opus-4-8', 'claude-haiku-4-5'],
  ollama: ['qwen3:8b', 'llama3.2', 'mistral', 'gemma3'],
  openrouter: ['anthropic/claude-sonnet-4.5', 'openai/gpt-5.1', 'meta-llama/llama-3.3-70b-instruct'],
};

export async function fetchProviderModels(provider) {
  try {
    const response = await fetch(`/api/provider_models?provider=${encodeURIComponent(provider)}`);
    if (response.ok) {
      const data = await response.json();
      if (Array.isArray(data.models) && data.models.length > 0) {
        return data.models;
      }
    }
  } catch {
    // fall through to the static fallback
  }
  return FALLBACK_PROVIDER_MODELS[provider] || [];
}
