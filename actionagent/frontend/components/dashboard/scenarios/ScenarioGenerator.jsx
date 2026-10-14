import React, { useCallback, useEffect, useState } from 'react';
import { Button, Card, Panel } from '../primitives';
import BrowserPanel from '../BrowserPanel';
import ExplorationList from '../explorations/ExplorationList';
import ExplorationReview from '../explorations/ExplorationReview';
import ExplorerStart from '../projects/ExplorerStart';
import { Notice, Select } from './fields';
import { requestJson } from './request';
import { navigateTo } from '../../../utils/dashboardPath';

// Generating scenarios: the engine's explorer walks a project's app in its
// sandbox's browser and proposes the questions a user would ask, each with
// a rubric. Its proposals are the project's explorations (the same records
// the project's Explorations tab reviews); here they are reviewed and
// accepted into a set of a collection rather than the project's evaluation.
//
// The explorer is a model run, so it needs a provider key; the project's
// sandbox must be booted, and its browser can be watched live while it walks.
export default function ScenarioGenerator({ projects, collections, onAccepted }) {
  const [projectId, setProjectId] = useState('');
  const [project, setProject] = useState(null);
  const [modelItem, setModelItem] = useState(null);
  const [browser, setBrowser] = useState({ sandbox: null, modes: [] });
  const [explorations, setExplorations] = useState([]);
  const [selectedId, setSelectedId] = useState(null);
  const [destination, setDestination] = useState({ collectionId: '', setId: '' });
  const [collection, setCollection] = useState(null);
  const [error, setError] = useState(null);

  const loadProject = useCallback(async () => {
    if (!projectId) return;
    try {
      const [projectData, capabilities, sandboxes, explorationData] = await Promise.all([
        requestJson(`/api/projects/${projectId}`, { fallback: 'Could not load the project' }),
        requestJson('/api/projects/capabilities').catch(() => ({})),
        requestJson('/api/sandboxes').catch(() => ({})),
        requestJson(`/api/explorations?project_id=${projectId}`, { fallback: "Could not list the project's explorations" }),
      ]);
      const loaded = projectData.project;
      setProject(loaded);
      setModelItem((capabilities.items || []).find((item) => item.key === 'model_credentials') || null);
      const sessionId = loaded?.sandbox?.session_id;
      setBrowser({
        sandbox: (sandboxes.sandboxes || []).find((sandbox) => sandbox.session_id === sessionId) || null,
        modes: sandboxes.browser_modes || [],
      });
      setExplorations(explorationData.explorations || []);
      setError(null);
    } catch (e) {
      setError(e.message);
    }
  }, [projectId]);

  useEffect(() => {
    setProject(null);
    setSelectedId(null);
    loadProject();
  }, [loadProject]);

  // The chosen collection's products and sets, for the destination picker.
  useEffect(() => {
    if (!destination.collectionId) {
      setCollection(null);
      return;
    }
    requestJson(`/api/scenario_catalogs/${destination.collectionId}`)
      .then((data) => setCollection(data.catalog))
      .catch((e) => setError(e.message));
  }, [destination.collectionId]);

  const sets = (collection?.products || []).flatMap((product) => (product.sets || []).map((set) => ({ ...set, product })));
  const chosenSet = sets.find((set) => String(set.id) === String(destination.setId));

  // A collection named after the project, with a product on the project and
  // an "explored" set, as the destination for its first generated scenarios.
  const createDestination = async () => {
    try {
      const created = await requestJson('/api/scenario_catalogs', {
        method: 'POST', body: { catalog: { name: project.name } }, fallback: 'Could not create the collection',
      });
      const id = created.catalogs[0].id;
      const product = await requestJson(`/api/scenario_catalogs/${id}/products`, {
        method: 'POST', body: { product: { name: project.name, project_id: project.id } }, fallback: 'Could not add the product',
      });
      const set = await requestJson(`/api/scenario_catalogs/${id}/products/${product.product.id}/sets`, {
        method: 'POST', body: { set: { name: 'Explored', key: 'explored', judge: { kind: 'llm' } } }, fallback: 'Could not add the set',
      });
      onAccepted?.();
      setDestination({ collectionId: String(id), setId: String(set.set.id) });
    } catch (e) {
      setError(e.message);
    }
  };

  const sandboxReady = project?.sandbox_state === 'ready';
  const current = selectedId || explorations[0]?.id;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }} data-testid="scenarios-generator">
      <Card>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <p style={{ margin: 0, fontSize: 13, color: 'var(--color-text-secondary)' }}>
            Pick a project. The explorer walks its running app in the sandbox&apos;s browser and proposes scenarios, which you edit and accept
            into a set below. Nothing is added until you accept it.
          </p>
          <Select label="Project" value={projectId} onChange={setProjectId} testId="scenarios-generator-project">
            <option value="">Choose a project…</option>
            {projects.map((entry) => <option key={entry.id} value={entry.id}>{entry.name}</option>)}
          </Select>
          {projects.length === 0 && (
            <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>
              No projects yet. <a href="#" onClick={(event) => { event.preventDefault(); navigateTo('/projects/new'); }}>Create one</a> from a repository first.
            </span>
          )}
        </div>
      </Card>

      {error && <Notice tone="error">{error}</Notice>}

      {project && (
        <>
          {modelItem && !modelItem.ok && (
            <Notice tone="error">
              The explorer runs on a model: {modelItem.detail || 'no provider has credentials'}.{' '}
              <a href="#" onClick={(event) => { event.preventDefault(); navigateTo('/settings?tab=api-keys'); }}>Add a provider key</a>, then start it.
            </Notice>
          )}
          {!sandboxReady && (
            <Notice>
              {project.name}&apos;s sandbox is {project.sandbox_state || 'not booted'}. The explorer walks the app the sandbox serves:{' '}
              <a href="#" onClick={(event) => { event.preventDefault(); navigateTo(`/projects/${project.id}`); }}>boot it on the project&apos;s page</a>.
            </Notice>
          )}

          <ExplorerStart
            projectId={project.id}
            sandboxReady={sandboxReady}
            onStarted={(exploration) => {
              setSelectedId(exploration.id);
              loadProject();
            }}
          />

          {sandboxReady && browser.sandbox && browser.modes.length > 0 && (
            <Panel title="The sandbox's browser" meta="watch the explorer walk the app" bodyStyle={{ padding: 12 }}>
              <BrowserPanel sandbox={browser.sandbox} modes={browser.modes} />
            </Panel>
          )}

          <Panel title="Accept into" testId="scenarios-generator-destination" bodyStyle={{ padding: 12, display: 'flex', flexDirection: 'column', gap: 8 }}>
            <div style={{ display: 'grid', gap: 8, gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))' }}>
              <Select label="Collection" value={destination.collectionId} onChange={(value) => setDestination({ collectionId: value, setId: '' })}>
                <option value="">Choose a collection…</option>
                {collections.map((entry) => <option key={entry.id} value={entry.id}>{entry.name}</option>)}
              </Select>
              <Select label="Set" value={destination.setId} onChange={(value) => setDestination((current) => ({ ...current, setId: value }))}>
                <option value="">{collection && sets.length === 0 ? 'The collection has no sets yet' : 'Choose a set…'}</option>
                {sets.map((set) => <option key={set.id} value={set.id}>{set.product.name} / {set.name}</option>)}
              </Select>
            </div>
            <div>
              <Button size="sm" variant="ghost" onClick={createDestination}>New collection for {project.name}</Button>
            </div>
          </Panel>

          {explorations.length === 0 ? (
            <Card>
              <p style={{ margin: 0, fontSize: 13, color: 'var(--color-text-secondary)' }}>
                No explorations of {project.name} yet. Start the explorer above, or have a coding agent driving a browser submit what it found
                with the explorations_submit MCP tool.
              </p>
            </Card>
          ) : (
            <>
              <ExplorationList explorations={explorations} selectedId={current} onOpen={(exploration) => setSelectedId(exploration.id)} />
              {!chosenSet && <Notice>Choose the set to accept into, above.</Notice>}
              <ExplorationReview
                key={`${current}-${chosenSet?.id || 'none'}`}
                explorationId={current}
                requireScenarioSet
                scenarioSet={chosenSet ? { id: chosenSet.id, label: `${chosenSet.product.name} / ${chosenSet.name}` } : null}
                onAccepted={() => onAccepted?.()}
              />
            </>
          )}
        </>
      )}
    </div>
  );
}
