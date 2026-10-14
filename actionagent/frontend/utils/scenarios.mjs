// The Scenarios page's pure helpers: its URLs, export links, the scenario
// form's fields, and an import preview's changes grouped for display.
//
// A collection here is a scenario catalog (ScenarioCatalog): YAML that keeps
// its `catalog:` key, so documents written before the rename still import.

export const SCENARIO_TABS = ['collections', 'generate', 'import'];

const SCENARIOS_PATH = /^\/(?:scenarios|catalogs)(?:\/(\d+|generate|import))?\/?$/;

// { tab, collectionId } for a mount-relative path under /scenarios (or the
// old /catalogs). /scenarios/:id opens a collection, /scenarios/generate and
// /scenarios/import their tabs; anything else opens the collections list.
export function parseScenariosPath(path = '') {
  const match = String(path).match(SCENARIOS_PATH);
  const segment = match?.[1];
  if (!segment) return { tab: 'collections', collectionId: null };
  if (/^\d+$/.test(segment)) return { tab: 'collections', collectionId: Number(segment) };
  return { tab: segment, collectionId: null };
}

// The mount-relative path for a tab, or for one collection.
export function scenariosPath({ tab = 'collections', collectionId = null } = {}) {
  if (collectionId) return `/scenarios/${collectionId}`;
  return tab === 'collections' || !SCENARIO_TABS.includes(tab) ? '/scenarios' : `/scenarios/${tab}`;
}

// The export URL for a collection: the whole of it, or the products, sets
// and scenarios chosen by id. `inline` answers the YAML as text, for copying.
export function exportUrl(collectionId, { productIds = [], setIds = [], scenarioIds = [] } = {}, { inline = false } = {}) {
  const params = new URLSearchParams();
  if (productIds.length) params.set('product_ids', productIds.join(','));
  if (setIds.length) params.set('set_ids', setIds.join(','));
  if (scenarioIds.length) params.set('scenario_ids', scenarioIds.join(','));
  if (inline) params.set('disposition', 'inline');
  const query = params.toString();
  return `/api/scenario_catalogs/${collectionId}/export${query ? `?${query}` : ''}`;
}

// A comma- or newline-separated field as a list, trimmed, without blanks or repeats.
export function splitList(text) {
  const values = String(text ?? '').split(/[,\n]/).map((value) => value.trim()).filter(Boolean);
  return [...new Set(values)];
}

// A scenario's editable fields, as the form shows them.
export function scenarioForm(scenario = {}) {
  const expectations = scenario.expectations || {};
  return {
    key: scenario.key || '',
    prompt: scenario.prompt || '',
    notes: scenario.notes || '',
    tools: (expectations.tools || []).join(', '),
    contains: (expectations.contains || []).join(', '),
    notContains: (expectations.not_contains || []).join(', '),
    tags: (scenario.tags || []).join(', '),
    productionOnly: Boolean(scenario.production_only),
    enabled: scenario.enabled !== false,
  };
}

// The request body for a scenario from its form. `expect` always carries
// all three lists, so clearing one in the form clears it on the scenario.
export function scenarioPayload(form) {
  return {
    scenario: {
      key: form.key.trim(),
      prompt: form.prompt.trim(),
      notes: form.notes.trim(),
      expect: { tools: splitList(form.tools), contains: splitList(form.contains), not_contains: splitList(form.notContains) },
      tags: splitList(form.tags),
      production_only: form.productionOnly,
      enabled: form.enabled,
    },
  };
}

// Why a scenario form cannot be saved, or null. The server checks the same
// and more (a key it already holds, the key's format).
export function scenarioFormProblem(form) {
  if (!form.prompt.trim()) return 'A scenario needs a prompt.';
  if (form.key.trim() && !/^[^\s]+$/.test(form.key.trim())) return 'A key has no spaces.';
  return null;
}

// What the scenario's expectations say, in a line: "tools lookup_order ·
// contains refund".
export function expectationText(expectations = {}) {
  const parts = [];
  if (expectations.tools?.length) parts.push(`tools ${expectations.tools.join(', ')}`);
  if (expectations.contains?.length) parts.push(`contains ${expectations.contains.join(', ')}`);
  if (expectations.not_contains?.length) parts.push(`never ${expectations.not_contains.join(', ')}`);
  return parts.join(' · ');
}

const ACTION_ORDER = ['create', 'update', 'remove', 'keep'];

export const PREVIEW_ACTION_LABELS = {
  create: 'New',
  update: 'Overwritten',
  remove: 'Removed',
  keep: 'Kept (not in the document)',
};

// One preview (ScenarioCatalogImport#preview) as display groups:
// [{ action, label, changes }], in ACTION_ORDER, leaving out empty ones.
export function previewGroups(preview) {
  const changes = preview?.changes || [];
  return ACTION_ORDER
    .map((action) => ({ action, label: PREVIEW_ACTION_LABELS[action], changes: changes.filter((change) => change.action === action) }))
    .filter((group) => group.changes.length > 0);
}

// A preview in a sentence: what applying it does to which collection.
export function previewSummary(preview) {
  if (!preview) return '';
  const counts = preview.counts || {};
  const verb = preview.catalog?.action === 'create' ? 'Creates' : 'Updates';
  const parts = [
    `${counts.create || 0} new`,
    `${counts.update || 0} overwritten`,
    preview.mode === 'merge' ? `${counts.keep || 0} kept` : `${counts.remove || 0} removed`,
  ];
  return `${verb} ${preview.catalog?.key}: ${parts.join(', ')} (${preview.scenario_count} scenarios in the document).`;
}

// Whether applying the previews would overwrite or remove anything.
export function previewConflicts(previews = []) {
  return previews.some((preview) => (preview.counts?.update || 0) + (preview.counts?.remove || 0) > 0);
}

// The selection with `id` toggled.
export function toggleId(list, id) {
  return list.includes(id) ? list.filter((value) => value !== id) : [...list, id];
}
