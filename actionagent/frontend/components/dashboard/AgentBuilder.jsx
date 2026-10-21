import React, { useState, useEffect, useMemo } from 'react';
import AgentAvatar, { AGENT_PRESETS, INSTRUCTIONS, TOOLS } from '../AgentAvatar';
import { ICONS } from '../../utils/designTokens';
import { FALLBACK_PROVIDER_MODELS } from '../../utils/providerModels';
import { useProviderModels } from '../../hooks/useProviderModels';
import ModelPicker from './ModelPicker';
import {
  builderServices,
  builderTools,
  checkoutToolsEnabled,
  defaultApprovals,
  offeredTools,
  serverEnabled,
  toggleServer,
  workspaceUseLabel,
} from '../../utils/builderRoster.mjs';

const STEPS = [
  { id: 'basics', label: 'Basics', icon: '1' },
  { id: 'configure', label: 'Configure', icon: '2' },
  { id: 'review', label: 'Review', icon: '3' }
];

// The toolbox capabilities the lander's TOOLS doesn't draw, labelled for the
// builder's chips; anything else (a host schema tool) shows its own name.
const TOOL_CHIPS = {
  ...TOOLS,
  agents: { emoji: '\u{1F91D}', label: 'Delegate to agents' },
  ask: { emoji: '\u{1F64B}', label: 'Ask the user' },
};

// Fields on the Basics step; the slug is derived from the name, so its
// errors are the name's to show.
const BASICS_FIELDS = ['name', 'slug', 'description', 'provider', 'model'];

export default function AgentBuilder({ meta, onSave, onCancel, isLoading, initialDraft = null }) {
  const [currentStep, setCurrentStep] = useState(0);
  const [formData, setFormData] = useState({
    name: '',
    description: '',
    provider: 'openai',
    model: FALLBACK_PROVIDER_MODELS.openai[0],
    instructions: '',
    preset_type: 'terminal',
    instruction_sets: ['github'],
    tools: ['terminal', 'code'],
    mcp_servers: [],
    model_config: {
      temperature: 0.7
    },
    ...(initialDraft ? {
      name: initialDraft.name,
      description: initialDraft.description || '',
      instructions: initialDraft.instructions,
      provider: initialDraft.provider,
      model: initialDraft.model,
      tools: initialDraft.tools || [],
      instruction_sets: [],
      mcp_servers: initialDraft.mcp_servers || [],
    } : {})
  });

  // The provider's current model catalog (Ollama/OpenRouter live, hosted
  // providers curated server-side). A draft's own model stays selectable.
  const loadedModels = useProviderModels([formData.provider]);
  const providerModels = useMemo(() => {
    const draftProvider = initialDraft?.model && initialDraft.provider;
    if (!draftProvider || !loadedModels[draftProvider]) return loadedModels;
    return { ...loadedModels, [draftProvider]: [...new Set([initialDraft.model, ...loadedModels[draftProvider]])] };
  }, [loadedModels]);

  // Keeps the selection one the provider's catalog lists as each list lands.
  const availableModels = providerModels[formData.provider];
  useEffect(() => {
    if (!availableModels?.length) return;
    setFormData(prev => availableModels.includes(prev.model) ? prev : { ...prev, model: availableModels[0] });
  }, [availableModels]);

  // What a new agent can be given (GET /api/agents/tool_roster): the tools
  // and MCP services a run would actually get. Once it lands, a selection
  // naming something it does not offer — a preset's or a draft's — is
  // narrowed to what does, so the agent is created with no dead names.
  const [roster, setRoster] = useState(null);
  const [rosterError, setRosterError] = useState(null);
  useEffect(() => {
    fetch('/api/agents/tool_roster')
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json();
      })
      .then((payload) => {
        setRoster(payload);
        setFormData(prev => ({ ...prev, tools: offeredTools(payload, prev.tools) }));
      })
      .catch((error) => setRosterError(error.message));
  }, []);

  // What the server rejected on the last Create Agent: { errors, fieldErrors }.
  const [submitErrors, setSubmitErrors] = useState(null);

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

  const selectPreset = (presetId) => {
    updateField('preset_type', presetId);
    if (AGENT_PRESETS[presetId]) {
      const preset = AGENT_PRESETS[presetId];
      updateField('instruction_sets', [...preset.instructions]);
      updateField('tools', offeredTools(roster, preset.tools));
    }
  };

  const canProceed = () => {
    switch (currentStep) {
      case 0: return formData.name.trim().length >= 2;
      case 1: return true;
      case 2: return true;
      default: return false;
    }
  };

  const handleSubmit = async () => {
    setSubmitErrors(null);
    // Side-effecting functions wait for approval unless the Tools tab says otherwise.
    const failure = await onSave({ ...formData, approval_required_tools: defaultApprovals(formData.tools) });
    if (!failure) return;

    setSubmitErrors(failure);
    if (Object.keys(failure.fieldErrors || {}).some(field => BASICS_FIELDS.includes(field))) {
      setCurrentStep(0);
    }
  };

  return (
    <div className="max-w-4xl mx-auto">
      {initialDraft && <div className="mb-4 p-4 rounded-lg border border-red-200 bg-red-50 text-sm text-gray-700">Prepared by your workspace assistant. Review the instructions, model, and tools before creating this agent.</div>}
      {/* Progress Steps */}
      <div className="mb-8">
        <div className="flex items-center justify-between">
          {STEPS.map((step, index) => (
            <div key={step.id} className="flex items-center">
              <div
                className={`flex items-center justify-center w-10 h-10 rounded-full border-2 transition-colors ${
                  index < currentStep
                    ? 'bg-red-500 border-red-500 text-white'
                    : index === currentStep
                    ? 'border-red-500 text-red-500'
                    : 'border-gray-300 text-gray-400'
                }`}
              >
                {index < currentStep ? '✓' : step.icon}
              </div>
              <span className={`ml-2 text-sm font-medium ${
                index <= currentStep ? 'text-gray-900' : 'text-gray-400'
              }`}>
                {step.label}
              </span>
              {index < STEPS.length - 1 && (
                <div className={`w-24 h-0.5 mx-4 ${
                  index < currentStep ? 'bg-red-500' : 'bg-gray-200'
                }`} />
              )}
            </div>
          ))}
        </div>
      </div>

      {submitErrors && (
        <div role="alert" className="mb-4 p-4 rounded-lg border border-red-300 bg-red-50 text-sm text-red-800">
          <p className="font-medium">The agent could not be created:</p>
          <ul className="mt-1 list-disc list-inside">
            {submitErrors.errors.map(message => <li key={message}>{message}</li>)}
          </ul>
        </div>
      )}

      {/* Step Content */}
      <div className="bg-white rounded-xl border border-gray-200 p-8">
        {currentStep === 0 && (
          <BasicsStep
            formData={formData}
            updateField={updateField}
            providerModels={providerModels}
            fieldErrors={submitErrors?.fieldErrors || {}}
          />
        )}
        {currentStep === 1 && (
          <ConfigureStep
            formData={formData}
            meta={meta}
            roster={roster}
            rosterError={rosterError}
            toggleArrayItem={toggleArrayItem}
            updateField={updateField}
            selectPreset={selectPreset}
          />
        )}
        {currentStep === 2 && (
          <ReviewStep formData={formData} roster={roster} />
        )}
      </div>

      {/* Navigation */}
      <div className="flex justify-between mt-6">
        <button
          onClick={currentStep === 0 ? onCancel : () => setCurrentStep(currentStep - 1)}
          className="px-6 py-2 border border-gray-300 rounded-lg text-gray-700 hover:bg-gray-50 transition-colors"
        >
          {currentStep === 0 ? 'Cancel' : 'Back'}
        </button>

        <button
          onClick={currentStep === STEPS.length - 1 ? handleSubmit : () => setCurrentStep(currentStep + 1)}
          disabled={!canProceed() || isLoading}
          className={`px-6 py-2 rounded-lg transition-colors ${
            canProceed() && !isLoading
              ? 'bg-red-500 text-white hover:bg-red-600'
              : 'bg-gray-200 text-gray-400 cursor-not-allowed'
          }`}
        >
          {currentStep === STEPS.length - 1 ? 'Create Agent' : 'Continue'}
        </button>
      </div>
    </div>
  );
}

function FieldErrors({ messages }) {
  if (!messages.length) return null;
  return (
    <p className="mt-1 text-sm text-red-600">{messages.join('. ')}</p>
  );
}

// Step 1: Basics
function BasicsStep({ formData, updateField, providerModels, fieldErrors }) {
  const errorsFor = (...fields) => fields.flatMap(field => fieldErrors[field] || []);

  return (
    <div className="space-y-6">
      <h2 className="text-xl font-semibold text-gray-900">Basic Information</h2>
      <p className="text-gray-500">Give your agent a name and configure its AI provider.</p>

      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Agent Name *</label>
          <input
            type="text"
            value={formData.name}
            onChange={(e) => updateField('name', e.target.value)}
            placeholder="My Awesome Agent"
            className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500 focus:border-transparent"
          />
          <FieldErrors messages={errorsFor('name', 'slug')} />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Description</label>
          <textarea
            value={formData.description}
            onChange={(e) => updateField('description', e.target.value)}
            placeholder="What does this agent do?"
            rows={3}
            className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500 focus:border-transparent"
          />
          <FieldErrors messages={errorsFor('description')} />
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Provider</label>
            <select
              value={formData.provider}
              onChange={(e) => {
                updateField('provider', e.target.value);
                updateField('model', providerModels[e.target.value][0]);
              }}
              className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500"
            >
              {Object.keys(providerModels).map(provider => (
                <option key={provider} value={provider}>
                  {provider.charAt(0).toUpperCase() + provider.slice(1)}
                </option>
              ))}
            </select>
            <FieldErrors messages={errorsFor('provider')} />
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Model</label>
            <ModelPicker
              value={formData.model}
              models={providerModels[formData.provider]}
              onChange={(model) => updateField('model', model)}
              className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500"
            />
            <FieldErrors messages={errorsFor('model')} />
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Temperature: {formData.model_config.temperature}
          </label>
          <input
            type="range"
            min="0"
            max="1"
            step="0.1"
            value={formData.model_config.temperature}
            onChange={(e) => updateField('model_config', { ...formData.model_config, temperature: parseFloat(e.target.value) })}
            className="w-full accent-red-500"
          />
          <div className="flex justify-between text-xs text-gray-400">
            <span>Precise</span>
            <span>Creative</span>
          </div>
        </div>
      </div>
    </div>
  );
}

// Step 2: Configure (instructions, tools, system prompt - matching lander pattern)
function ConfigureStep({ formData, meta, roster, rosterError, toggleArrayItem, updateField, selectPreset }) {
  const presets = Object.keys(AGENT_PRESETS);
  const allInstructions = Object.keys(INSTRUCTIONS);
  const tools = builderTools(roster);
  const { callable, unavailable } = builderServices(roster);

  return (
    <div className="space-y-6">
      <h2 className="text-xl font-semibold text-gray-900">Configure Agent</h2>
      <p className="text-gray-500">Choose a preset or customize instructions and tools.</p>

      {/* Agent Preview - matching lander hero layout */}
      <div className="flex justify-center py-6 bg-gradient-to-br from-gray-50 to-gray-100 rounded-xl">
        <div className="flex flex-col items-center">
          {/* Instructions above */}
          <div className="flex gap-2 mb-2">
            {formData.instruction_sets.map(id => {
              const instr = INSTRUCTIONS[id];
              return instr ? (
                <span key={id} className="text-lg" title={instr.label}>{instr.emoji}</span>
              ) : null;
            })}
          </div>
          <AgentAvatar size={120} />
          {/* Tools below */}
          <div className="flex gap-2 mt-2">
            {formData.tools.map(id => {
              const tool = TOOLS[id];
              return tool ? (
                <span key={id} className="text-lg" title={tool.label}>{tool.emoji}</span>
              ) : null;
            })}
          </div>
        </div>
      </div>

      {/* Preset Selection - matching lander's preset buttons */}
      <div>
        <label className="block text-sm font-medium text-gray-700 mb-3">Quick Presets</label>
        <div className="flex flex-wrap gap-2">
          {presets.map(preset => (
            <button
              key={preset}
              onClick={() => selectPreset(preset)}
              className={`px-4 py-2 rounded-lg border-2 text-sm transition-all ${
                formData.preset_type === preset
                  ? 'border-red-500 bg-red-50 text-red-700'
                  : 'border-gray-200 hover:border-gray-300 text-gray-600'
              }`}
            >
              <span className="capitalize">{preset.replace(/([A-Z])/g, ' $1').trim()}</span>
            </button>
          ))}
        </div>
      </div>

      {/* Instructions - matching lander's chip selector */}
      <div>
        <label className="block text-sm font-medium text-gray-700 mb-3">
          <strong>Instructions</strong>
          <span className="text-gray-400 font-normal ml-2">System/developer messages</span>
        </label>
        <div className="flex flex-wrap gap-2">
          {allInstructions.map(id => {
            const instr = INSTRUCTIONS[id];
            return (
              <button
                key={id}
                onClick={() => toggleArrayItem('instruction_sets', id)}
                className={`flex items-center gap-1.5 px-3 py-1.5 rounded-full text-sm transition-colors ${
                  formData.instruction_sets.includes(id)
                    ? 'bg-red-500 text-white'
                    : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                }`}
              >
                <span>{instr.emoji}</span>
                <span>{instr.label}</span>
              </button>
            );
          })}
        </div>
      </div>

      {/* Tools: the toolbox capabilities and host schema tools a run is offered */}
      <div>
        <label className="block text-sm font-medium text-gray-700 mb-3">
          <strong>Tools</strong>
          <span className="text-gray-400 font-normal ml-2">Functions the model can call</span>
        </label>
        {rosterError && <p className="text-sm text-red-600">Could not load the tools this workspace offers: {rosterError}</p>}
        {!roster && !rosterError && <p className="text-sm text-gray-400">Loading tools…</p>}
        <div className="flex flex-wrap gap-2" data-testid="builder-tools">
          {tools.map(tool => (
            <RosterChip
              key={tool.key}
              testId={`builder-tool-${tool.key}`}
              on={formData.tools.includes(tool.key)}
              onClick={() => toggleArrayItem('tools', tool.key)}
              emoji={TOOL_CHIPS[tool.key]?.emoji || '\u{1F9F1}'}
              label={TOOL_CHIPS[tool.key]?.label || tool.name}
              title={tool.description || tool.name}
            />
          ))}
        </div>
        {checkoutToolsEnabled(formData.tools) && (
          <p className="mt-2 text-xs text-gray-500" data-testid="builder-checkout-hint">
            Terminal, Filesystem, Edit and Database act in a repository checkout: choose one under Checkout when you run the agent.
          </p>
        )}
      </div>

      {/* MCP services a dashboard run can call, and the ones it can't */}
      <div>
        <label className="block text-sm font-medium text-gray-700 mb-3">
          <strong>MCP servers</strong>
          <span className="text-gray-400 font-normal ml-2">Every tool the server serves is offered</span>
        </label>
        {roster && callable.length === 0 && (
          <p className="text-sm text-gray-500">
            No MCP server this workspace can call yet. Register one with its URL in <code>ActionAgent.mcp_catalog</code>, or
            boot a project's checkout to offer its app runtime.
          </p>
        )}
        <div className="flex flex-wrap gap-2" data-testid="builder-mcp-servers">
          {callable.map(service => (
            <RosterChip
              key={service.key}
              testId={`builder-mcp-${service.key}`}
              on={serverEnabled(formData.mcp_servers, service.key)}
              onClick={() => updateField('mcp_servers', toggleServer(formData.mcp_servers, service))}
              emoji={service.runtime ? '\u{1F4E6}' : '\u{1F50C}'}
              label={service.name}
              hint={workspaceUseLabel(service)}
              title={[service.description, service.transport].filter(Boolean).join(' · ')}
            />
          ))}
        </div>
        {unavailable.length > 0 && (
          <details className="mt-3 text-sm" data-testid="builder-mcp-unavailable">
            <summary className="cursor-pointer text-gray-500">
              {unavailable.length} catalog server{unavailable.length === 1 ? '' : 's'} a run can't call
            </summary>
            <ul className="mt-2 space-y-1">
              {unavailable.map(service => (
                <li key={service.key} className="text-xs text-gray-500">
                  <span className="font-medium text-gray-700">{service.name}</span> — {service.unavailable_reason}
                </li>
              ))}
            </ul>
          </details>
        )}
      </div>

      {/* System Instructions */}
      <div>
        <label className="block text-sm font-medium text-gray-700 mb-2">System Instructions</label>
        <textarea
          value={formData.instructions}
          onChange={(e) => updateField('instructions', e.target.value)}
          placeholder="You are a helpful AI assistant that..."
          rows={4}
          className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500 focus:border-transparent font-mono text-sm"
        />
      </div>
    </div>
  );
}

// Step 3: Review
function ReviewStep({ formData, roster }) {
  const serviceName = (entry) => {
    const key = typeof entry === 'string' ? entry : entry?.key;
    return roster?.services?.find(service => service.key === key)?.name || entry?.name || key;
  };

  return (
    <div className="space-y-6">
      <h2 className="text-xl font-semibold text-gray-900">Review Your Agent</h2>
      <p className="text-gray-500">Confirm the configuration before creating your agent.</p>

      <div className="grid grid-cols-2 gap-8">
        {/* Preview - matching lander layout */}
        <div className="flex flex-col items-center py-6 bg-gradient-to-br from-gray-50 to-gray-100 rounded-xl">
          <div className="flex gap-2 mb-2">
            {formData.instruction_sets.map(id => {
              const instr = INSTRUCTIONS[id];
              return instr ? (
                <span key={id} className="text-lg" title={instr.label}>{instr.emoji}</span>
              ) : null;
            })}
          </div>
          <AgentAvatar size={100} />
          <div className="flex gap-2 mt-2">
            {formData.tools.map(id => {
              const tool = TOOLS[id];
              return tool ? (
                <span key={id} className="text-lg" title={tool.label}>{tool.emoji}</span>
              ) : null;
            })}
          </div>
          <h3 className="mt-4 text-lg font-semibold text-gray-900">{formData.name}</h3>
          <p className="text-sm text-gray-500">{formData.description || 'No description'}</p>
        </div>

        {/* Details */}
        <div className="space-y-4">
          <div>
            <span className="text-sm font-medium text-gray-500">Provider / Model</span>
            <p className="text-gray-900">{formData.provider} / {formData.model}</p>
          </div>

          <div>
            <span className="text-sm font-medium text-gray-500">Temperature</span>
            <p className="text-gray-900">{formData.model_config.temperature}</p>
          </div>

          <div>
            <span className="text-sm font-medium text-gray-500">Instructions</span>
            <div className="flex flex-wrap gap-1 mt-1">
              {formData.instruction_sets.length > 0 ? (
                formData.instruction_sets.map(id => {
                  const instr = INSTRUCTIONS[id];
                  return instr ? (
                    <span key={id} className="px-2 py-0.5 bg-gray-100 rounded text-xs">
                      {instr.emoji} {instr.label}
                    </span>
                  ) : null;
                })
              ) : (
                <span className="text-gray-400 text-sm">None selected</span>
              )}
            </div>
          </div>

          <div>
            <span className="text-sm font-medium text-gray-500">Tools</span>
            <div className="flex flex-wrap gap-1 mt-1">
              {formData.tools.length > 0 ? (
                formData.tools.map(id => (
                  <span key={id} className="px-2 py-0.5 bg-red-100 text-red-700 rounded text-xs">
                    {TOOL_CHIPS[id] ? `${TOOL_CHIPS[id].emoji} ${TOOL_CHIPS[id].label}` : id}
                  </span>
                ))
              ) : (
                <span className="text-gray-400 text-sm">None selected</span>
              )}
            </div>
          </div>

          {defaultApprovals(formData.tools).length > 0 && (
            <div>
              <span className="text-sm font-medium text-gray-500">Waits for your approval</span>
              <p className="text-gray-900 text-sm font-mono">{defaultApprovals(formData.tools).join(', ')}</p>
            </div>
          )}

          <div>
            <span className="text-sm font-medium text-gray-500">MCP servers</span>
            <div className="flex flex-wrap gap-1 mt-1">
              {formData.mcp_servers.length > 0 ? (
                formData.mcp_servers.map(entry => (
                  <span key={serviceName(entry)} className="px-2 py-0.5 bg-red-100 text-red-700 rounded text-xs">
                    {serviceName(entry)}
                  </span>
                ))
              ) : (
                <span className="text-gray-400 text-sm">None selected</span>
              )}
            </div>
          </div>
        </div>
      </div>

      {formData.instructions && (
        <div>
          <span className="text-sm font-medium text-gray-500">System Instructions</span>
          <pre className="mt-2 p-4 bg-gray-50 rounded-lg text-sm text-gray-700 whitespace-pre-wrap font-mono">
            {formData.instructions}
          </pre>
        </div>
      )}
    </div>
  );
}

// A chip in the builder's Tools and MCP servers rows.
function RosterChip({ on, onClick, emoji, label, hint, title, testId }) {
  return (
    <button
      type="button"
      data-testid={testId}
      aria-pressed={on}
      onClick={onClick}
      title={title}
      className={`flex items-center gap-1.5 px-3 py-1.5 rounded-full text-sm transition-colors ${
        on ? 'bg-red-500 text-white' : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
      }`}
    >
      <span>{emoji}</span>
      <span>{label}</span>
      {hint && <span className={`text-xs ${on ? 'text-red-100' : 'text-gray-400'}`}>· {hint}</span>}
    </button>
  );
}
