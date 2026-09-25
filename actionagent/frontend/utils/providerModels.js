import { createRequestCache } from './requestCache.mjs';

// Model options for the dashboard's model pickers. The server is the source
// of truth (/api/provider_models): curated current lists for hosted
// providers, live lookups for Ollama (the account's configured host) and
// OpenRouter, and the host's RubyLLM model registry when it has one. These
// fallbacks only cover a failed fetch.
export const FALLBACK_PROVIDER_MODELS = {
  openai: ['gpt-5.1', 'gpt-5', 'gpt-5-mini', 'gpt-5-nano'],
  anthropic: ['claude-opus-5', 'claude-fable-5', 'claude-sonnet-5', 'claude-opus-4-8', 'claude-haiku-4-5'],
  ollama: ['qwen3:8b', 'llama3.2', 'mistral', 'gemma3'],
  openrouter: ['anthropic/claude-sonnet-4.5', 'openai/gpt-5.1', 'meta-llama/llama-3.3-70b-instruct'],
};

// The providers an agent can run on, in the order the pickers list them
// (ActionAgent::Agent::PROVIDERS).
export const MODEL_PROVIDERS = Object.keys(FALLBACK_PROVIDER_MODELS);

// How long a provider's list is reused once loaded, so pickers mounting
// again (another suite opened, the form reopened) don't fetch it again.
const CACHE_TTL_MS = 5 * 60 * 1000;

const cachedProviderModels = createRequestCache(loadProviderModels, {
  ttlMs: CACHE_TTL_MS,
  keep: (models) => models !== null,
});

// Returns the provider's model ids: the server's list, or the fallback when
// the request fails.
export async function fetchProviderModels(provider) {
  return (await cachedProviderModels(provider)) ?? (FALLBACK_PROVIDER_MODELS[provider] || []);
}

// Forgets every loaded list, for a change that alters what the server
// returns: a provider credential saved or removed.
export function clearProviderModels() {
  cachedProviderModels.clear();
}

// Returns the server's list for `provider`, or null when the request fails or
// the list is empty.
async function loadProviderModels(provider) {
  try {
    const response = await fetch(`/api/provider_models?provider=${encodeURIComponent(provider)}`);
    if (response.ok) {
      const data = await response.json();
      if (Array.isArray(data.models) && data.models.length > 0) {
        return data.models;
      }
    }
  } catch {
    // the caller falls back to the static list
  }
  return null;
}
