// Model names for the dashboard's model pickers, and the comma-separated
// model lists the evaluation forms submit.
//
// A scenario run reads each name the way ActiveAgent::Evals::ModelSpec.parse
// does (lib/active_agent/evals/model_spec.rb):
//
//   "anthropic/claude-sonnet-5"      → anthropic, claude-sonnet-5
//   "claude-haiku-4-5"               → anthropic, inferred from the name
//   "qwen3:8b"                       → ollama, inferred from the tag
//   "meta-llama/llama-3.3-70b"       → openrouter, whose vendor is no provider
//   "openrouter/anthropic/claude-3"  → openrouter, anthropic/claude-3
//   "llama3.2"                       → no provider: the agent's own runs it
//
// The inference rules below are a copy of ModelSpec::DEFAULT_INFERENCE_RULES.
// actionagent/test/fixtures/model_spec_cases.json holds the cases both copies
// are tested against.

const INFERENCE_RULES = [
  [/^claude/i, 'anthropic'],
  [/^(gpt-|o\d|chatgpt|text-embedding)/i, 'openai'],
  [/:/, 'ollama'],
];

// The providers a scenario run resolves a model name against:
// ActionAgent::ScenarioEvaluationRunner::CANDIDATE_PROVIDERS. `mock` is the
// framework's test double. The pickers never offer its models, but a name
// whose first segment is `mock` still resolves to it.
export const RUN_PROVIDERS = ['openai', 'anthropic', 'ollama', 'openrouter', 'mock'];

// Returns `{ provider, model }` for a model name, as ModelSpec.parse resolves
// it against `providers`. `provider` is null when the name names none, so the
// evaluated agent's own provider would run it.
export function resolveModelName(name, providers = RUN_PROVIDERS) {
  const raw = String(name ?? '').trim();
  const slash = raw.indexOf('/');
  const head = slash >= 0 ? raw.slice(0, slash) : raw;
  const rest = slash >= 0 ? raw.slice(slash + 1) : '';

  if (rest.trim()) {
    if (providers.includes(head)) return { provider: head, model: rest };
    if (providers.includes('openrouter')) return { provider: 'openrouter', model: raw };
  }

  const rule = INFERENCE_RULES.find(([pattern, provider]) => pattern.test(raw) && providers.includes(provider));
  return { provider: rule ? rule[1] : null, model: raw };
}

// Returns the name that runs `id` on `provider`: the bare id when it resolves
// there by itself, else `provider/id`. `llama3.2` from Ollama becomes
// `ollama/llama3.2`, and `anthropic/claude-sonnet-4.5` from OpenRouter becomes
// `openrouter/anthropic/claude-sonnet-4.5`.
export function qualifiedModelName(provider, id, providers = RUN_PROVIDERS) {
  const resolved = resolveModelName(id, providers);
  return resolved.provider === provider && resolved.model === id ? id : `${provider}/${id}`;
}

// Returns each id a `{ provider: [ids] }` catalog lists for `providers`, as
// `{ provider, id, qualified }`, in `providers` order and each provider's own
// order, blank ids dropped. `qualified` is the id's qualifiedModelName.
function catalogEntries(catalog, providers) {
  return providers.flatMap((provider) =>
    (catalog?.[provider] || []).flatMap((id) => {
      const bare = String(id ?? '').trim();
      return bare ? [{ provider, id: bare, qualified: qualifiedModelName(provider, bare) }] : [];
    }));
}

/**
 * Returns a `{ provider: [ids] }` catalog as one list of picker options, in
 * `providers` order and each provider's own order, blanks and repeats dropped.
 *
 * @param {Object<string, string[]>} catalog
 * @param {Object} options
 * @param {string[]} options.providers - the providers to include, in order
 * @param {boolean} [options.qualify=true] - name each model so that a
 *   scenario run resolves it to the provider that listed it
 *   (qualifiedModelName). False offers the ids bare.
 * @returns {string[]}
 */
export function buildModelOptions(catalog, { providers, qualify = true }) {
  const names = catalogEntries(catalog, providers).map((entry) => (qualify ? entry.qualified : entry.id));
  return [...new Set(names)];
}

/**
 * Returns `models` with each name the catalog lists renamed for the way the
 * field is read, as `{ models, restore }`: its qualified name when `qualify`,
 * its bare id otherwise. A name the catalog does not list is kept as it is,
 * and repeats are dropped.
 *
 *   requalifyModels(['llama3.2', 'gpt-5'], { ollama: ['llama3.2'] }, { providers: ['ollama'], qualify: true })
 *   // → { models: ['ollama/llama3.2', 'gpt-5'], restore: new Map() }
 *
 * Two providers can list the same id, so bare ids can merge picks:
 * `ollama/gpt-5.1` and OpenAI's `gpt-5.1` both become `gpt-5.1`. `restore`
 * maps each bare id to the names it replaced, and passing it back when
 * qualifying gives those names back. Otherwise a bare id two providers list
 * takes the first provider's qualified name. Qualifying returns an empty
 * `restore`.
 *
 * @param {string[]} models
 * @param {Object<string, string[]>} catalog
 * @param {Object} options
 * @param {string[]} options.providers - the providers whose ids to rename
 * @param {boolean} options.qualify
 * @param {Map<string, string[]>} [options.restore] - a `restore` returned
 *   when the names were made bare
 * @returns {{ models: string[], restore: Map<string, string[]> }}
 */
export function requalifyModels(models, catalog, { providers, qualify, restore = new Map() }) {
  const entries = catalogEntries(catalog, providers);
  const current = new Set(entries.map((entry) => (qualify ? entry.qualified : entry.id)));
  const renamed = new Map();
  entries.forEach((entry) => {
    const from = qualify ? entry.id : entry.qualified;
    if (!renamed.has(from)) renamed.set(from, qualify ? entry.qualified : entry.id);
  });
  const rename = (name) => (current.has(name) ? name : renamed.get(name) ?? name);

  if (qualify) {
    const names = models.flatMap((name) => restore.get(name) ?? [rename(name)]);
    return { models: [...new Set(names)], restore: new Map() };
  }

  const replaced = new Map();
  models.forEach((name) => {
    const bare = rename(name);
    replaced.set(bare, [...(replaced.get(bare) || []), name]);
  });
  return { models: [...replaced.keys()], restore: replaced };
}

// Returns the models in a comma-separated list, trimmed, blanks and repeats
// dropped: `"gpt-5, , qwen3:8b, gpt-5"` → `["gpt-5", "qwen3:8b"]`.
export function parseModelList(text) {
  return [...new Set(String(text ?? '').split(',').map((name) => name.trim()).filter(Boolean))];
}

// Returns the comma-separated form of a model list.
export function serializeModelList(models) {
  return models.join(', ');
}

// Returns `models` with every model in the comma-separated `text` appended
// that it does not already hold.
export function appendModels(models, text) {
  return [...new Set([...models, ...parseModelList(text)])];
}

// Splits the text typed into a multi-model field at its last comma, into the
// models finished before it and the draft after it: `"a, b, c"` →
// `{ complete: "a, b", rest: "c" }`. Text without a comma is all draft.
export function splitDraft(text) {
  const cut = text.lastIndexOf(',');
  if (cut < 0) return { complete: '', rest: text.trimStart() };
  return { complete: text.slice(0, cut), rest: text.slice(cut + 1).trimStart() };
}

// Returns whether an input event carrying `text` is a suggestion picked from
// `options`. Browsers report a pick as `insertReplacementText`, or report no
// input type at all, while typing reports `insertText`.
export function isSuggestionPick(inputType, text, options) {
  return (!inputType || inputType === 'insertReplacementText') && options.includes(text);
}

// Returns what a key pressed in a multi-model field's draft does:
//   - 'commit':      Enter while a draft is typed
//   - 'removeLast':  Backspace in an empty draft with models chosen, unless
//                    the key is auto-repeating
//   - null:          nothing beyond the key's usual effect
export function draftKeyAction({ key, repeat = false }, draft, count) {
  if (key === 'Enter' && draft.trim()) return 'commit';
  if (key === 'Backspace' && !repeat && draft === '' && count > 0) return 'removeLast';
  return null;
}
