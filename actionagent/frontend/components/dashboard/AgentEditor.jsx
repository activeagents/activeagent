import React, { useState, useEffect } from 'react';
import { AGENT_PRESETS } from '../AgentAvatar';
import { TYPOGRAPHY } from '../../utils/designTokens';
import { useProviderModels } from '../../hooks/useProviderModels';
import ModelPicker from './ModelPicker';
import { useTheme } from '../../contexts/ThemeContext';
import { paletteFor, ACCENT } from '../../utils/dashboardTheme';
import { PageHeader, Tabs, Chip, SegmentedControl, MONO, TONE } from './primitives';
import { fmtRuns, fmtErrorRate, fmtDuration, fmtAgentCost, evalTone } from '../../utils/agentStats.mjs';
import { fmtPercent } from '../../utils/evalFormat.mjs';
import TracesView from './TracesView';
import InteractionsView from './InteractionsView';
import EvaluationsView from './EvaluationsView';
import AgentAnalytics from './AgentAnalytics';
import AgentToolsTab from './AgentToolsTab';

// The agent page has three tabs — what the agent did (Activity), how well it
// did it (Quality) and what it is (Config) — each holding the sections an
// operator moves between without leaving the page. `activeTab` names the
// section, so a deep link such as initialTab="metrics" lands on Quality with
// Metrics selected.
const TABS = [
  {
    id: 'activity',
    label: 'Activity',
    sections: [
      { id: 'traces', label: 'Traces' },
      { id: 'interactions', label: 'Interactions' }
    ]
  },
  {
    id: 'quality',
    label: 'Quality',
    sections: [
      { id: 'evals', label: 'Evaluations' },
      { id: 'metrics', label: 'Metrics' }
    ]
  },
  {
    id: 'config',
    label: 'Config',
    sections: [
      { id: 'config', label: 'Configuration' },
      { id: 'instructions', label: 'Instructions' },
      { id: 'tools', label: 'Tools' },
      { id: 'versions', label: 'Versions' },
      { id: 'code', label: 'Code' }
    ]
  }
];

const TOP_TABS = TABS.map(({ id, label }) => ({ id, label }));

const tabOf = (sectionId) => TABS.find((tab) => tab.sections.some((section) => section.id === sectionId));

// Soft tint + strong text. Dark mode lifts the text off the base hue instead
// of using the light-mode ink, which would go unreadable on a dark tint.
const BADGE_TONES = {
  success: { light: ['#dcfce7', '#166534'], dark: ['rgba(22,163,74,0.18)', '#4ade80'] },
  warning: { light: ['#fef9c3', '#854d0e'], dark: ['rgba(234,179,8,0.18)', '#facc15'] },
  neutral: { light: ['#f3f4f6', '#4b5563'], dark: ['rgba(255,255,255,0.1)', 'rgba(255,255,255,0.7)'] },
  error: { light: ['#fee2e2', '#991b1b'], dark: ['rgba(220,38,38,0.18)', '#f87171'] },
  info: { light: ['#dbeafe', '#1e40af'], dark: ['rgba(59,130,246,0.18)', '#60a5fa'] }
};

const STATUS_TONE = { active: 'success', draft: 'warning', archived: 'neutral', failed: 'error', trial: 'info' };

export function Badge({ tone = 'neutral', mono = false, darkMode, children }) {
  const [bg, fg] = (BADGE_TONES[tone] || BADGE_TONES.neutral)[darkMode ? 'dark' : 'light'];
  return (
    <span
      style={{
        background: bg,
        color: fg,
        borderRadius: '999px',
        padding: '2px 8px',
        fontSize: '11px',
        fontWeight: 600,
        fontFamily: mono ? TYPOGRAPHY.mono : undefined,
        whiteSpace: 'nowrap'
      }}
    >
      {children}
    </span>
  );
}

// One primary per view — the primary here is Run Agent. Shared with the
// runner so both agent pages use the same control; `testId` lets that page
// mark the buttons its browser tests drive.
export function Button({ variant = 'secondary', size = 'md', onClick, disabled, colors, title, testId, children }) {
  const pad = size === 'sm' ? '5px 10px' : '7px 14px';
  const base = {
    padding: pad,
    borderRadius: '8px',
    fontSize: '13px',
    fontWeight: 500,
    cursor: disabled ? 'not-allowed' : 'pointer',
    transition: 'background 0.15s ease, border-color 0.15s ease',
    whiteSpace: 'nowrap'
  };
  const variants = {
    primary: { background: disabled ? colors.mutedBg : ACCENT, color: disabled ? colors.textMuted : '#ffffff', border: '1px solid transparent' },
    secondary: { background: 'transparent', color: colors.textCell, border: `1px solid ${colors.inputBorder}` },
    danger: { background: 'transparent', color: '#dc2626', border: '1px solid rgba(220,38,38,0.4)' }
  };
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      title={title}
      data-testid={testId}
      style={{ ...base, ...(variants[variant] || variants.secondary) }}
    >
      {children}
    </button>
  );
}

// The figures the scorecard recorded for this agent over its window, in one
// mono row under the header. The error rate reads in the error colour once
// there is one; the evaluation score carries its tone.
function StatsStrip({ stats }) {
  const errorRate = fmtErrorRate(stats.success_rate);
  const hasErrors = errorRate !== '—' && parseFloat(errorRate) > 0;
  const items = [
    { label: stats.window_days ? `RUNS ${stats.window_days}D` : 'RUNS', value: fmtRuns(stats.runs) },
    { label: 'ERRORS', value: errorRate, color: hasErrors ? 'var(--color-error-text)' : undefined },
    { label: 'AVG', value: fmtDuration(stats.avg_duration_ms) },
    { label: 'EVAL', value: fmtPercent(stats.eval_score), color: TONE[evalTone(stats.eval_score)].text },
    { label: 'COST', value: fmtAgentCost(stats.cost) }
  ];
  return (
    <div data-testid="agent-stats" style={{ display: 'flex', flexWrap: 'wrap', gap: 28, fontFamily: MONO }}>
      {items.map((item) => (
        <div key={item.label} style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <span style={{ fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.04em', color: 'var(--color-text-muted)' }}>{item.label}</span>
          <span style={{ fontSize: 16, fontWeight: 500, color: item.color || 'var(--color-text-primary)' }}>{item.value}</span>
        </div>
      ))}
    </div>
  );
}

export default function AgentEditor({ agent, meta, onSave, onDelete, onRun, onDuplicate, onRunReport, onBack, isLoading, initialTab }) {
  const { darkMode } = useTheme();
  const colors = paletteFor(darkMode);
  const [activeTab, setActiveTab] = useState(() => (tabOf(initialTab) ? initialTab : 'config'));
  const [formData, setFormData] = useState({
    name: agent.name || '',
    description: agent.description || '',
    provider: agent.provider || 'openai',
    model: agent.model || 'gpt-4o-mini',
    instructions: agent.instructions || '',
    action_prompts: agent.actionPrompts || agent.action_prompts || [],
    preset_type: agent.presetType || agent.preset_type || 'terminal',
    appearance: agent.appearance || {},
    instruction_sets: agent.instructionSets || agent.instruction_sets || [],
    tools: agent.tools || [],
    approval_required_tools: agent.approvalRequiredTools || agent.approval_required_tools || [],
    mcp_servers: agent.mcpServers || agent.mcp_servers || [],
    model_config: agent.modelConfig || agent.model_config || { temperature: 0.7 },
    status: agent.status || 'draft'
  });
  const [versions, setVersions] = useState([]);
  const [hasChanges, setHasChanges] = useState(false);
  const [codePreview, setCodePreview] = useState('');
  // The provider's current model catalog. The agent's saved model is kept
  // even when the list lacks it (e.g. a locally pulled Ollama model on another
  // machine), so opening the editor can't clobber it.
  const providerModels = useProviderModels([formData.provider]);

  useEffect(() => {
    // Check for unsaved changes
    const changed = JSON.stringify(formData) !== JSON.stringify({
      name: agent.name || '',
      description: agent.description || '',
      provider: agent.provider || 'openai',
      model: agent.model || 'gpt-4o-mini',
      instructions: agent.instructions || '',
      action_prompts: agent.actionPrompts || agent.action_prompts || [],
      preset_type: agent.presetType || agent.preset_type || 'terminal',
      appearance: agent.appearance || {},
      instruction_sets: agent.instructionSets || agent.instruction_sets || [],
      tools: agent.tools || [],
      approval_required_tools: agent.approvalRequiredTools || agent.approval_required_tools || [],
      mcp_servers: agent.mcpServers || agent.mcp_servers || [],
      model_config: agent.modelConfig || agent.model_config || { temperature: 0.7 },
      status: agent.status || 'draft'
    });
    setHasChanges(changed);
  }, [formData, agent]);

  useEffect(() => {
    if (activeTab === 'versions') {
      loadVersions();
    } else if (activeTab === 'code') {
      loadCodePreview();
    }
  }, [activeTab]);

  const loadVersions = async () => {
    try {
      const response = await fetch(`/api/agents/${agent.id}/versions`);
      const data = await response.json();
      setVersions(data.versions);
    } catch (error) {
      console.error('Failed to load versions:', error);
    }
  };

  const loadCodePreview = async () => {
    try {
      const response = await fetch(`/api/agents/${agent.id}/export`);
      const data = await response.json();
      setCodePreview(data.code);
    } catch (error) {
      console.error('Failed to load code preview:', error);
    }
  };

  const updateField = (field, value) => {
    setFormData(prev => ({ ...prev, [field]: value }));
  };

  const toggleArrayItem = (field, item) => {
    setFormData(prev => {
      const current = prev[field] || [];
      const updated = current.includes(item)
        ? current.filter(i => i !== item)
        : [...current, item];
      return { ...prev, [field]: updated };
    });
  };

  const handleSave = () => {
    onSave(formData);
  };

  const tab = tabOf(activeTab);
  // Opening a tab lands on its first section, unless the current section is
  // already inside it (a deep link to Metrics keeps Metrics).
  const openTab = (id) => {
    if (tab.id === id) return;
    setActiveTab(TABS.find((entry) => entry.id === id).sections[0].id);
  };
  const isObservability = tab.id !== 'config';
  // The Tools tab brings its own cards and its own action bar, the way the
  // observability panels do — a roster is a pair of lists, not a form.
  const isTools = activeTab === 'tools';

  const versionCount = agent.version_count ?? agent.versionCount;
  const metaLine = [agent.model, versionCount != null && `v${versionCount}`].filter(Boolean).join(' · ');

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
      {/* Header — the trail back to Agents, the identity, then the two
          page-level actions; the recorded figures sit in a strip under it. */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
        <PageHeader
          crumbs={[{ label: 'Agents', onClick: onBack }]}
          glyph="@"
          title={formData.name || agent.name || 'Untitled agent'}
          meta={metaLine || undefined}
          badges={(
            <>
              <Badge tone={STATUS_TONE[formData.status] || 'neutral'} darkMode={darkMode}>
                {formData.status}
              </Badge>
              {hasChanges && (
                <Badge tone="info" darkMode={darkMode}>unsaved</Badge>
              )}
            </>
          )}
          actions={(
            <>
              {onDuplicate && (
                <Button variant="secondary" colors={colors} onClick={onDuplicate}>Duplicate</Button>
              )}
              <Button variant="primary" colors={colors} onClick={onRun}>Run Agent</Button>
            </>
          )}
        />
        {formData.description && (
          <p style={{ fontSize: '13px', color: 'var(--color-text-secondary)', margin: 0 }}>
            {formData.description}
          </p>
        )}
        {agent.stats && <StatsStrip stats={agent.stats} />}
      </div>

      {/* Three tabs; the row under them switches the section within one. */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
        <Tabs tabs={TOP_TABS} active={tab.id} onChange={openTab} ariaLabel="Agent sections" />
        {isObservability ? (
          <div role="group" aria-label={`${tab.label} sections`} style={{ display: 'flex', flexWrap: 'wrap', gap: '8px' }}>
            {tab.sections.map((section) => (
              <Chip key={section.id} selected={section.id === activeTab} onClick={() => setActiveTab(section.id)}>
                {section.label}
              </Chip>
            ))}
          </div>
        ) : (
          <SegmentedControl
            options={tab.sections.map(({ id, label }) => ({ value: id, label }))}
            value={activeTab}
            onChange={setActiveTab}
            style={{ flexWrap: 'wrap' }}
          />
        )}
      </div>

      {/* Observability panels bring their own cards; config panels get one. */}
      {isTools ? (
        <AgentToolsTab
          agent={agent}
          formData={formData}
          updateField={updateField}
          onSave={handleSave}
          hasChanges={hasChanges}
          isLoading={isLoading}
        />
      ) : isObservability ? (
        <div>
          {activeTab === 'traces' && <TracesView agentId={agent.id} embedded />}
          {activeTab === 'metrics' && <AgentAnalytics agent={agent} embedded />}
          {activeTab === 'interactions' && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
              {/* The run report is a separate view — runs and their cohorts,
                  not conversation streams — and this is its only entry. */}
              {onRunReport && (
                <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
                  <button
                    type="button"
                    onClick={onRunReport}
                    style={{
                      background: 'none',
                      border: 'none',
                      cursor: 'pointer',
                      fontFamily: MONO,
                      fontSize: '11px',
                      color: 'var(--color-info)'
                    }}
                  >
                    {'run report ->'}
                  </button>
                </div>
              )}
              <InteractionsView agentId={agent.id} embedded />
            </div>
          )}
          {activeTab === 'evals' && <EvaluationsView embedded agentId={agent.id} />}
        </div>
      ) : (
        <div
          style={{
            background: colors.cardBg,
            border: `1px solid ${colors.cardBorder}`,
            borderRadius: '12px',
            padding: '20px'
          }}
        >
          {activeTab === 'config' && (
            <ConfigTab
              formData={formData}
              updateField={updateField}
              providerModels={providerModels}
              colors={colors}
              darkMode={darkMode}
              onDelete={onDelete}
            />
          )}
          {activeTab === 'instructions' && (
            <InstructionsTab formData={formData} updateField={updateField} meta={meta} toggleArrayItem={toggleArrayItem} colors={colors} />
          )}
          {activeTab === 'versions' && (
            <VersionsTab versions={versions} agentId={agent.id} onRestore={loadVersions} colors={colors} darkMode={darkMode} />
          )}
          {activeTab === 'code' && (
            <CodeTab code={codePreview} colors={colors} />
          )}
        </div>
      )}

      {/* Surfaces once something actually changed, on every tab: the header
          badge reports "unsaved" from anywhere, so the control has to follow
          it or an edit made on Configuration looks unsavable from Traces. */}
      {hasChanges && !isTools && (
        <div
          style={{
            position: 'sticky',
            bottom: '0',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: '12px',
            background: colors.cardBg,
            border: `1px solid ${colors.borderStrong}`,
            borderRadius: '12px',
            padding: '10px 14px',
            boxShadow: 'var(--shadow-popover)'
          }}
        >
          <span style={{ fontSize: '13px', color: colors.textSecondary }}>Unsaved changes</span>
          <div style={{ display: 'flex', gap: '8px' }}>
            <Button variant="primary" size="sm" colors={colors} onClick={handleSave} disabled={isLoading}>
              {isLoading ? 'Saving…' : 'Save Changes'}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

// Shared form chrome so every config panel reads as one surface.
const labelStyle = (colors) => ({
  display: 'block',
  fontSize: '13px',
  fontWeight: 500,
  color: colors.textCell,
  marginBottom: '6px'
});

const fieldStyle = (colors) => ({
  width: '100%',
  padding: '8px 12px',
  borderRadius: '8px',
  border: `1px solid ${colors.inputBorder}`,
  background: colors.inputBg,
  color: colors.textPrimary,
  // textarea defaults to monospace; only the fields that mean it opt in.
  fontFamily: 'inherit',
  fontSize: '13px'
});

const microLabel = (colors) => ({
  fontFamily: TYPOGRAPHY.mono,
  fontSize: '11px',
  fontWeight: 600,
  letterSpacing: '0.06em',
  textTransform: 'uppercase',
  color: colors.textSecondary
});

function ConfigTab({ formData, updateField, providerModels, colors, darkMode, onDelete }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '16px' }}>
        <div>
          <label style={labelStyle(colors)}>Agent Name</label>
          <input
            type="text"
            value={formData.name}
            onChange={(e) => updateField('name', e.target.value)}
            className="aa-field"
            style={fieldStyle(colors)}
          />
        </div>
        <div>
          <label style={labelStyle(colors)}>Preset Type</label>
          <select
            value={formData.preset_type}
            onChange={(e) => updateField('preset_type', e.target.value)}
            className="aa-field"
            style={fieldStyle(colors)}
          >
            {Object.keys(AGENT_PRESETS).map(preset => (
              <option key={preset} value={preset}>{preset}</option>
            ))}
          </select>
        </div>
      </div>

      <div>
        <label style={labelStyle(colors)}>Description</label>
        <textarea
          value={formData.description}
          onChange={(e) => updateField('description', e.target.value)}
          rows={3}
          className="aa-field"
          style={{ ...fieldStyle(colors), resize: 'vertical' }}
        />
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '16px' }}>
        <div>
          <label style={labelStyle(colors)}>Provider</label>
          <select
            value={formData.provider}
            onChange={(e) => {
              updateField('provider', e.target.value);
              updateField('model', providerModels[e.target.value][0]);
            }}
            className="aa-field"
            style={fieldStyle(colors)}
          >
            {Object.keys(providerModels).map(p => (
              <option key={p} value={p}>{p.charAt(0).toUpperCase() + p.slice(1)}</option>
            ))}
          </select>
        </div>
        <div>
          <label style={labelStyle(colors)}>Model</label>
          <ModelPicker
            value={formData.model}
            models={providerModels[formData.provider]}
            onChange={(model) => updateField('model', model)}
            className="aa-field"
            style={{ ...fieldStyle(colors), fontFamily: TYPOGRAPHY.mono }}
          />
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '16px' }}>
        <div>
          <label style={labelStyle(colors)}>
            Temperature{' '}
            <span style={{ fontFamily: TYPOGRAPHY.mono, color: colors.textSecondary }}>
              {formData.model_config.temperature}
            </span>
          </label>
          <input
            type="range"
            min="0"
            max="1"
            step="0.1"
            value={formData.model_config.temperature}
            onChange={(e) => updateField('model_config', { ...formData.model_config, temperature: parseFloat(e.target.value) })}
            style={{ width: '100%', accentColor: ACCENT }}
          />
        </div>
        <div>
          <label style={labelStyle(colors)}>Status</label>
          <select
            value={formData.status}
            onChange={(e) => updateField('status', e.target.value)}
            className="aa-field"
            style={fieldStyle(colors)}
          >
            <option value="draft">Draft</option>
            <option value="active">Active</option>
            <option value="archived">Archived</option>
          </select>
        </div>
      </div>

      {onDelete && (
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: '12px',
            borderTop: `1px solid ${colors.cardBorder}`,
            paddingTop: '16px'
          }}
        >
          <div>
            <div style={microLabel(colors)}>Danger zone</div>
            <p style={{ fontSize: '13px', color: colors.textMuted, margin: '4px 0 0' }}>
              Deleting an agent removes its configuration and version history.
            </p>
          </div>
          <Button variant="danger" size="sm" colors={colors} onClick={onDelete}>Delete Agent</Button>
        </div>
      )}
    </div>
  );
}

function InstructionsTab({ formData, updateField, meta, toggleArrayItem, colors }) {
  const actionPrompts = formData.action_prompts || [];

  const updateActionPrompt = (index, patch) => {
    updateField('action_prompts', actionPrompts.map((ap, i) => (i === index ? { ...ap, ...patch } : ap)));
  };

  const addActionPrompt = () => {
    updateField('action_prompts', [...actionPrompts, { name: '', prompt: '', expose_as_tool: false }]);
  };

  const removeActionPrompt = (index) => {
    updateField('action_prompts', actionPrompts.filter((_, i) => i !== index));
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
      <div>
        <label style={labelStyle(colors)}>System Instructions</label>
        <textarea
          value={formData.instructions}
          onChange={(e) => updateField('instructions', e.target.value)}
          placeholder="You are a helpful AI assistant..."
          rows={12}
          className="aa-field"
          style={{ ...fieldStyle(colors), fontFamily: TYPOGRAPHY.mono, resize: 'vertical' }}
        />
      </div>

      {/* Named action prompts — each becomes an invokable agent action whose
          system prompt stacks on top of the base instructions (activeagent's
          actions-as-prompts model). The default #ask action always exists. */}
      <div>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '6px' }}>
          <label style={{ ...labelStyle(colors), marginBottom: 0 }}>Action Prompts</label>
          <Button variant="secondary" size="sm" colors={colors} onClick={addActionPrompt}>+ Add action</Button>
        </div>
        <p style={{ fontSize: '12px', color: colors.textMuted, margin: '0 0 12px' }}>
          Named actions run with their prompt stacked below the system instructions.
          The default <span style={{ fontFamily: TYPOGRAPHY.mono }}>#ask</span> action uses the system instructions alone.
        </p>
        {actionPrompts.length > 0 && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
            {actionPrompts.map((action, index) => (
              <div
                key={index}
                style={{
                  border: `1px solid ${colors.cardBorder}`,
                  borderRadius: '10px',
                  padding: '12px',
                  display: 'flex',
                  flexDirection: 'column',
                  gap: '8px'
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                  <span style={{ fontFamily: TYPOGRAPHY.mono, fontSize: '13px', color: colors.textMuted }}>#</span>
                  <input
                    type="text"
                    value={action.name}
                    onChange={(e) => updateActionPrompt(index, { name: e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '_') })}
                    placeholder="action_name"
                    className="aa-field"
                    style={{ ...fieldStyle(colors), flex: 1, padding: '6px 10px', fontFamily: TYPOGRAPHY.mono }}
                  />
                  <label style={{ display: 'flex', alignItems: 'center', gap: '6px', fontSize: '12px', color: colors.textSecondary, whiteSpace: 'nowrap' }}>
                    <input
                      type="checkbox"
                      checked={!!action.expose_as_tool}
                      onChange={(e) => updateActionPrompt(index, { expose_as_tool: e.target.checked })}
                      style={{ accentColor: ACCENT }}
                    />
                    Expose as tool
                  </label>
                  <button
                    type="button"
                    onClick={() => removeActionPrompt(index)}
                    title="Remove action"
                    style={{
                      fontFamily: TYPOGRAPHY.mono,
                      fontSize: '12px',
                      color: colors.textMuted,
                      background: 'none',
                      border: 'none',
                      cursor: 'pointer',
                      padding: '4px'
                    }}
                  >
                    {'[x]'}
                  </button>
                </div>
                <textarea
                  value={action.prompt}
                  onChange={(e) => updateActionPrompt(index, { prompt: e.target.value })}
                  placeholder="This action's system prompt, applied on top of the base instructions..."
                  rows={4}
                  className="aa-field"
                  style={{ ...fieldStyle(colors), fontFamily: TYPOGRAPHY.mono, resize: 'vertical' }}
                />
              </div>
            ))}
          </div>
        )}
      </div>

      <div>
        <label style={labelStyle(colors)}>Instruction Sets</label>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '8px' }}>
          {meta.instructionSets?.map(instruction => {
            const on = formData.instruction_sets.includes(instruction);
            return (
              <button
                key={instruction}
                type="button"
                onClick={() => toggleArrayItem('instruction_sets', instruction)}
                style={{
                  padding: '5px 12px',
                  borderRadius: '999px',
                  fontSize: '13px',
                  cursor: 'pointer',
                  border: `1px solid ${on ? ACCENT : colors.inputBorder}`,
                  background: on ? ACCENT : 'transparent',
                  color: on ? '#ffffff' : colors.textCell
                }}
              >
                {instruction}
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}

function VersionsTab({ versions, agentId, onRestore, colors, darkMode }) {
  const handleRestore = async (versionId) => {
    if (!confirm('Restore this version? This will create a new version with the restored configuration.')) return;

    try {
      await fetch(`/api/agents/${agentId}/restore`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ version_id: versionId })
      });
      onRestore();
    } catch (error) {
      console.error('Failed to restore version:', error);
    }
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
      <p style={{ fontSize: '13px', color: colors.textSecondary, margin: 0 }}>
        View and restore previous versions of this agent.
      </p>

      {versions.length > 0 ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '10px' }}>
          {versions.map((version) => {
            const isLatest = version.is_latest || version.isLatest;
            return (
              <div
                key={version.id}
                style={{
                  display: 'flex',
                  alignItems: 'flex-start',
                  justifyContent: 'space-between',
                  gap: '12px',
                  padding: '14px',
                  borderRadius: '10px',
                  border: `1px solid ${isLatest ? ACCENT : colors.cardBorder}`,
                  background: isLatest ? 'rgba(239,68,68,0.06)' : 'transparent'
                }}
              >
                <div style={{ minWidth: 0 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                    <span style={{ fontFamily: TYPOGRAPHY.mono, fontSize: '13px', fontWeight: 600, color: colors.textPrimary }}>
                      v{version.version_number || version.versionNumber}
                    </span>
                    {isLatest && <Badge tone="error" darkMode={darkMode}>current</Badge>}
                  </div>
                  <p style={{ fontSize: '13px', color: colors.textCell, margin: '4px 0 0' }}>
                    {version.change_summary || version.changeSummary}
                  </p>
                  <p style={{ fontFamily: TYPOGRAPHY.mono, fontSize: '11px', color: colors.textMuted, margin: '4px 0 0' }}>
                    {new Date(version.created_at || version.createdAt).toLocaleString()}
                  </p>
                </div>
                {!isLatest && (
                  <Button variant="secondary" size="sm" colors={colors} onClick={() => handleRestore(version.id)}>
                    Restore
                  </Button>
                )}
              </div>
            );
          })}
        </div>
      ) : (
        <EmptyState colors={colors} glyph="[#]" title="No version history" hint="Saving a change records a new version." />
      )}
    </div>
  );
}

function CodeTab({ code, colors }) {
  const copyToClipboard = () => {
    navigator.clipboard.writeText(code);
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <p style={{ fontSize: '13px', color: colors.textSecondary, margin: 0 }}>Generated Ruby code for this agent.</p>
        <Button variant="secondary" size="sm" colors={colors} onClick={copyToClipboard}>Copy</Button>
      </div>

      <pre
        style={{
          padding: '16px',
          background: 'var(--color-background)',
          color: 'var(--color-text-primary)',
          border: '1px solid var(--color-border)',
          borderRadius: '10px',
          overflowX: 'auto',
          fontFamily: TYPOGRAPHY.mono,
          fontSize: '12px',
          lineHeight: 1.6,
          margin: 0
        }}
      >
        <code>{code || 'Loading...'}</code>
      </pre>
    </div>
  );
}

function EmptyState({ colors, glyph, title, hint }) {
  return (
    <div style={{ textAlign: 'center', padding: '40px 20px' }}>
      <div style={{ fontFamily: TYPOGRAPHY.mono, fontSize: '20px', color: colors.textMuted }}>{glyph}</div>
      <div style={{ fontSize: '14px', fontWeight: 600, color: colors.textPrimary, marginTop: '10px' }}>{title}</div>
      <p style={{ fontSize: '13px', color: colors.textMuted, margin: '6px auto 0', maxWidth: '420px' }}>{hint}</p>
    </div>
  );
}
