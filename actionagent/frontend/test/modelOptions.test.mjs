import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  RUN_PROVIDERS,
  appendModels,
  buildModelOptions,
  draftKeyAction,
  isSuggestionPick,
  parseModelList,
  qualifiedModelName,
  requalifyModels,
  resolveModelName,
  serializeModelList,
  splitDraft,
} from '../utils/modelOptions.mjs';

// The evaluation pickers offer a name only when a scenario run reads it as
// the model the catalog listed, on the provider that listed it. These pin
// the copy of ActiveAgent::Evals::ModelSpec.parse that decides that, and the
// comma-separated value the forms submit.

// Shared with actionagent/test/model_picker_names_test.rb, which runs the same
// cases through ModelSpec.parse.
const CASES = JSON.parse(readFileSync(new URL('../../test/fixtures/model_spec_cases.json', import.meta.url), 'utf8'));

const PROVIDERS = ['openai', 'anthropic', 'ollama', 'openrouter'];

test('names resolve against the providers a scenario run does', () => {
  assert.deepEqual(RUN_PROVIDERS, CASES.providers);
});

test('each shared name resolves to the provider and model ModelSpec.parse gives', () => {
  CASES.names.forEach(({ name, provider, model }) => {
    assert.deepEqual(resolveModelName(name), { provider, model }, JSON.stringify(name));
  });
});

test('each shared id is named the way ModelSpec.parse runs it on its provider', () => {
  CASES.qualified.forEach(({ provider, id, name }) => {
    assert.equal(qualifiedModelName(provider, id), name, `${provider} ${id}`);
    assert.deepEqual(resolveModelName(name), { provider, model: id }, name);
  });
});

test('an inference rule whose provider is not offered is skipped', () => {
  assert.deepEqual(resolveModelName('qwen3:8b', ['openai', 'anthropic']), { provider: null, model: 'qwen3:8b' });
  assert.deepEqual(resolveModelName('meta-llama/llama-3.3-70b', ['openai']), { provider: null, model: 'meta-llama/llama-3.3-70b' });
});

test('options follow provider order and each list, without blanks or repeats', () => {
  const catalog = {
    openrouter: ['qwen/qwen3-32b', 'anthropic/claude-sonnet-4.5'],
    openai: ['gpt-5.1', '', 'gpt-5.1', 'gpt-5'],
    anthropic: ['claude-opus-5'],
    ollama: ['llama3.2', null],
  };

  assert.deepEqual(buildModelOptions(catalog, { providers: PROVIDERS }), [
    'gpt-5.1', 'gpt-5', 'claude-opus-5', 'ollama/llama3.2', 'qwen/qwen3-32b', 'openrouter/anthropic/claude-sonnet-4.5',
  ]);
});

test('options cover only the providers asked for, named as a run resolves them', () => {
  const catalog = { openai: ['gpt-5.1'], ollama: ['llama3.2', 'gpt-oss:20b'], openrouter: ['anthropic/claude-sonnet-4.5'] };

  // Ollama alone is offered, and its names still resolve against every
  // provider a run knows.
  assert.deepEqual(buildModelOptions(catalog, { providers: ['ollama'] }), ['ollama/llama3.2', 'ollama/gpt-oss:20b']);
});

test('unqualified options are the bare ids, each once', () => {
  const catalog = { openai: ['gpt-5.1'], ollama: ['llama3.2', 'gpt-5.1'], openrouter: ['anthropic/claude-sonnet-4.5'] };

  assert.deepEqual(buildModelOptions(catalog, { providers: PROVIDERS, qualify: false }), [
    'gpt-5.1', 'llama3.2', 'anthropic/claude-sonnet-4.5',
  ]);
});

test('options skip providers the catalog does not hold', () => {
  assert.deepEqual(buildModelOptions({ anthropic: ['claude-opus-5'] }, { providers: PROVIDERS }), ['claude-opus-5']);
  assert.deepEqual(buildModelOptions(undefined, { providers: PROVIDERS }), []);
});

const REQUALIFY_CATALOG = {
  openai: ['gpt-5.1'],
  anthropic: ['claude-haiku-4-5'],
  ollama: ['llama3.2', 'gpt-oss:20b'],
  openrouter: ['anthropic/claude-sonnet-4.5', 'qwen/qwen3-32b'],
};

test('models picked bare are named for a scenario run once scenarios appear', () => {
  const picked = ['anthropic/claude-sonnet-4.5', 'llama3.2', 'gpt-oss:20b', 'gpt-5.1', 'qwen/qwen3-32b', 'mistral'];
  const { models, restore } = requalifyModels(picked, REQUALIFY_CATALOG, { providers: PROVIDERS, qualify: true });

  assert.deepEqual(models, [
    'openrouter/anthropic/claude-sonnet-4.5', 'ollama/llama3.2', 'ollama/gpt-oss:20b', 'gpt-5.1', 'qwen/qwen3-32b', 'mistral',
  ]);
  assert.equal(restore.size, 0);
});

test('models picked for a scenario run go back to their bare ids once scenarios are cleared', () => {
  const picked = ['openrouter/anthropic/claude-sonnet-4.5', 'ollama/llama3.2', 'claude-haiku-4-5', 'ollama/typed:tag'];

  assert.deepEqual(requalifyModels(picked, REQUALIFY_CATALOG, { providers: PROVIDERS, qualify: false }).models, [
    'anthropic/claude-sonnet-4.5', 'llama3.2', 'claude-haiku-4-5', 'ollama/typed:tag',
  ]);
});

test('requalifying both ways returns the models picked', () => {
  const bare = ['anthropic/claude-sonnet-4.5', 'llama3.2', 'gpt-5.1'];
  const qualified = requalifyModels(bare, REQUALIFY_CATALOG, { providers: PROVIDERS, qualify: true }).models;

  assert.deepEqual(requalifyModels(qualified, REQUALIFY_CATALOG, { providers: PROVIDERS, qualify: false }).models, bare);
});

test('a bare id two providers list is qualified for the first of them', () => {
  const catalog = { openai: ['shared-model'], ollama: ['shared-model'] };

  assert.deepEqual(requalifyModels(['shared-model'], catalog, { providers: PROVIDERS, qualify: true }).models, ['openai/shared-model']);
});

test('picks that share a bare id merge once scenarios are cleared, and come back with them', () => {
  const catalog = { openai: ['gpt-5.1'], ollama: ['gpt-5.1', 'llama3.2'] };
  const cleared = requalifyModels(['gpt-5.1', 'ollama/gpt-5.1', 'ollama/llama3.2'], catalog, { providers: PROVIDERS, qualify: false });

  assert.deepEqual(cleared.models, ['gpt-5.1', 'llama3.2']);
  assert.deepEqual(
    requalifyModels([...cleared.models, 'claude-haiku-4-5'], catalog, { providers: PROVIDERS, qualify: true, restore: cleared.restore }).models,
    ['gpt-5.1', 'ollama/gpt-5.1', 'ollama/llama3.2', 'claude-haiku-4-5'],
  );
});

test('a pick for the second provider to list an id keeps that provider across a round trip', () => {
  const catalog = { openai: ['gpt-5.1'], ollama: ['gpt-5.1'] };
  const cleared = requalifyModels(['ollama/gpt-5.1'], catalog, { providers: PROVIDERS, qualify: false });

  assert.deepEqual(cleared.models, ['gpt-5.1']);
  assert.deepEqual(
    requalifyModels(cleared.models, catalog, { providers: PROVIDERS, qualify: true, restore: cleared.restore }).models,
    ['ollama/gpt-5.1'],
  );
});

test('a model list parses to trimmed names, blanks and repeats dropped', () => {
  assert.deepEqual(parseModelList('gpt-5, , qwen3:8b,gpt-5 ,ollama/llama3.2'), ['gpt-5', 'qwen3:8b', 'ollama/llama3.2']);
  assert.deepEqual(parseModelList(''), []);
  assert.deepEqual(parseModelList(undefined), []);
});

test('a model list serializes to the comma-separated value the forms submit', () => {
  assert.equal(serializeModelList(['claude-haiku-4-5', 'qwen3:8b']), 'claude-haiku-4-5, qwen3:8b');
  assert.equal(serializeModelList([]), '');
  assert.deepEqual(parseModelList(serializeModelList(['a/b:c', 'd'])), ['a/b:c', 'd']);
});

test('appending adds only the models the list lacks', () => {
  assert.deepEqual(appendModels(['gpt-5'], 'qwen3:8b'), ['gpt-5', 'qwen3:8b']);
  assert.deepEqual(appendModels(['gpt-5'], ' gpt-5 , claude-opus-5,'), ['gpt-5', 'claude-opus-5']);
  assert.deepEqual(appendModels(['gpt-5'], '   '), ['gpt-5']);
});

test('typed text splits at its last comma into finished models and the draft', () => {
  assert.deepEqual(splitDraft('a, b, c'), { complete: 'a, b', rest: 'c' });
  assert.deepEqual(splitDraft('gpt-5,'), { complete: 'gpt-5', rest: '' });
  assert.deepEqual(splitDraft('gpt-5,  qwen'), { complete: 'gpt-5', rest: 'qwen' });
  assert.deepEqual(splitDraft('  qwen3'), { complete: '', rest: 'qwen3' });
  assert.deepEqual(splitDraft(''), { complete: '', rest: '' });
});

test('a suggestion pick is an offered option replacing the text, or arriving with no input type', () => {
  const options = ['gpt-5', 'gpt-5-mini'];

  assert.equal(isSuggestionPick('insertReplacementText', 'gpt-5-mini', options), true);
  assert.equal(isSuggestionPick(undefined, 'gpt-5-mini', options), true);
  assert.equal(isSuggestionPick('', 'gpt-5', options), true);
  // Typing a name that happens to be an option does not add it before the
  // user has finished.
  assert.equal(isSuggestionPick('insertText', 'gpt-5', options), false);
  assert.equal(isSuggestionPick('insertReplacementText', 'gpt-4', options), false);
  assert.equal(isSuggestionPick(undefined, 'gpt', options), false);
});

test('Enter commits a typed draft, and Backspace in an empty draft removes the last model once', () => {
  assert.equal(draftKeyAction({ key: 'Enter' }, 'qwen3', 0), 'commit');
  assert.equal(draftKeyAction({ key: 'Enter' }, '   ', 2), null);
  assert.equal(draftKeyAction({ key: 'Backspace' }, '', 2), 'removeLast');
  assert.equal(draftKeyAction({ key: 'Backspace', repeat: true }, '', 2), null);
  assert.equal(draftKeyAction({ key: 'Backspace' }, 'q', 2), null);
  assert.equal(draftKeyAction({ key: 'Backspace' }, '', 0), null);
  assert.equal(draftKeyAction({ key: 'a' }, '', 2), null);
});
