import React, { useState } from 'react';
import { Badge, Button, Card, MONO, SegmentedControl } from '../primitives';
import { Check, Field, Notice } from './fields';
import { requestJson } from './request';
import { previewConflicts, previewGroups, previewSummary } from '../../../utils/scenarios.mjs';

const SOURCES = [
  { value: 'document', label: 'Paste YAML' },
  { value: 'file', label: 'Upload a file' },
  { value: 'repository', label: 'From a repository' },
];

const PLACEHOLDER = `catalog: support_desk
products:
  - key: triage
    agent: TriageAgent
    sets:
      - key: smoke
        scenarios:
          - key: refund
            prompt: A customer asks for a refund.
            notes: Looks the order up before answering.
            expect: { tools: [lookup_order] }`;

const ACTION_TONES = { create: 'success', update: 'warning', remove: 'error', keep: 'muted' };

// Importing scenario YAML: pasted, uploaded, or read from a connected
// repository at a ref (every .yml under .activeagents/evals by default).
// Nothing is written until the preview shows, by key, what the import
// creates, overwrites and removes, and the person applies it. A document is
// matched to a collection by its `catalog:` key.
//
// "Keep what the document leaves out" (merge) is on by default, so a
// document holding one exported set or a few scenarios updates only those;
// off, the document replaces the collection, as a full export round trip
// expects.
export default function ScenarioImport({ onImported }) {
  const [source, setSource] = useState('document');
  const [document, setDocument] = useState('');
  const [fileName, setFileName] = useState('');
  const [repository, setRepository] = useState('');
  const [ref, setRef] = useState('');
  const [path, setPath] = useState('.activeagents/evals');
  const [merge, setMerge] = useState(true);
  const [previews, setPreviews] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const payload = () => {
    const mode = merge ? 'merge' : 'replace';
    if (source === 'repository') return { repository: repository.trim(), ref: ref.trim() || undefined, path: path.trim() || undefined, mode };
    return { document, mode, ...(fileName ? { source_path: fileName } : {}) };
  };
  const ready = source === 'repository' ? Boolean(repository.trim()) : Boolean(document.trim());

  // Any change to what is imported discards the preview, so Apply always
  // writes what was previewed.
  const edit = (setter) => (value) => {
    setter(value);
    setPreviews(null);
  };

  const run = async (fn) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  const preview = () => run(async () => {
    const data = await requestJson('/api/scenario_catalogs/preview', { method: 'POST', body: payload(), fallback: 'The preview failed' });
    setPreviews(data.previews || []);
  });

  const apply = () => run(async () => {
    const data = await requestJson('/api/scenario_catalogs', { method: 'POST', body: payload(), fallback: 'Import refused' });
    setPreviews(null);
    setDocument('');
    setFileName('');
    onImported?.(data.catalogs || []);
  });

  const readFile = (file) => {
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      setFileName(file.name);
      edit(setDocument)(String(reader.result || ''));
    };
    reader.onerror = () => setError(`Could not read ${file.name}.`);
    reader.readAsText(file);
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }} data-testid="scenarios-import">
      <Card>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <SegmentedControl options={SOURCES} value={source} onChange={(value) => { setSource(value); setPreviews(null); }} />
          {source === 'document' && (
            <Field label="YAML" value={document} onChange={edit(setDocument)} placeholder={PLACEHOLDER} mono multiline rows={12} testId="scenarios-import-yaml" />
          )}
          {source === 'file' && (
            <label style={{ display: 'flex', flexDirection: 'column', gap: 6, fontSize: 12, color: 'var(--color-text-secondary)' }}>
              A .yml or .yaml file, such as one exported from this page
              <input type="file" accept=".yml,.yaml,application/x-yaml,text/yaml" onChange={(event) => readFile(event.target.files?.[0])} />
              {fileName && <span style={{ fontFamily: MONO }}>{fileName} · {document.length} characters</span>}
            </label>
          )}
          {source === 'repository' && (
            <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))' }}>
              <Field label="Repository" value={repository} onChange={edit(setRepository)} placeholder="owner/name" mono />
              <Field label="Ref" value={ref} onChange={edit(setRef)} placeholder="the default branch when empty" mono />
              <Field label="Path" value={path} onChange={edit(setPath)} placeholder=".activeagents/evals or one .yml file" mono />
            </div>
          )}
          <Check label="Keep what the document leaves out (merge). Off: the document replaces the collection." checked={merge} onChange={edit(setMerge)} />
          <div style={{ display: 'flex', gap: 8 }}>
            <Button onClick={preview} disabled={busy || !ready} testId="scenarios-import-preview">{busy && !previews ? 'Reading…' : 'Preview'}</Button>
            <Button variant="primary" onClick={apply} disabled={busy || !previews || previews.length === 0} testId="scenarios-import-apply">
              {previewConflicts(previews || []) ? 'Apply, overwriting' : 'Apply'}
            </Button>
          </div>
        </div>
      </Card>

      {error && <Notice tone="error">{error}</Notice>}

      {previews && previews.map((entry) => <PreviewCard key={`${entry.catalog?.key}-${entry.source_path || ''}`} preview={entry} />)}
    </div>
  );
}

export function PreviewCard({ preview }) {
  const groups = previewGroups(preview);
  return (
    <Card testId="scenarios-import-preview-result">
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
        <Badge tone={preview.catalog?.action === 'create' ? 'success' : 'info'}>{preview.catalog?.action === 'create' ? 'new collection' : 'existing collection'}</Badge>
        <span style={{ fontSize: 13, color: 'var(--color-text-primary)' }}>{previewSummary(preview)}</span>
      </div>
      {preview.source_path && <div style={{ fontSize: 12, color: 'var(--color-text-secondary)', fontFamily: MONO, marginTop: 4 }}>{preview.source_path}</div>}
      {groups.length === 0 ? (
        <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--color-text-secondary)' }}>Nothing changes: the collection already holds this document.</p>
      ) : (
        <div style={{ display: 'grid', gap: 8, marginTop: 10 }}>
          {groups.map((group) => (
            <div key={group.action}>
              <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                <Badge tone={ACTION_TONES[group.action]}>{group.label}</Badge>
                <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>{group.changes.length}</span>
              </div>
              <ul style={{ margin: '4px 0 0', paddingLeft: 18, fontSize: 12, fontFamily: MONO, color: 'var(--color-text-secondary)' }}>
                {group.changes.slice(0, 50).map((change) => (
                  <li key={`${change.level}-${change.path}`}>{change.level} {change.path}</li>
                ))}
                {group.changes.length > 50 && <li>and {group.changes.length - 50} more</li>}
              </ul>
            </div>
          ))}
        </div>
      )}
    </Card>
  );
}
