import React, { useState, useEffect } from 'react';
import AgentAvatar, { AGENT_PRESETS, INSTRUCTIONS, TOOLS } from '../AgentAvatar';
import { ICONS } from '../../utils/designTokens';
import { FALLBACK_PROVIDER_MODELS, fetchProviderModels } from '../../utils/providerModels';

const STEPS = [
  { id: 'basics', label: 'Basics', icon: '1' },
  { id: 'configure', label: 'Configure', icon: '2' },
  { id: 'review', label: 'Review', icon: '3' }
];

export default function AgentBuilder({ meta, onSave, onCancel, isLoading }) {
  const [currentStep, setCurrentStep] = useState(0);
  const [providerModels, setProviderModels] = useState(FALLBACK_PROVIDER_MODELS);
  const [formData, setFormData] = useState({
    name: '',
    description: '',
    provider: 'openai',
    model: FALLBACK_PROVIDER_MODELS.openai[0],
    instructions: '',
    preset_type: 'terminal',
    instruction_sets: ['github'],
    tools: ['terminal', 'code'],
    model_config: {
      temperature: 0.7
    }
  });

  // Load the provider's current model catalog (Ollama/OpenRouter live,
  // hosted providers curated server-side); keep the selection valid.
  useEffect(() => {
    let cancelled = false;
    fetchProviderModels(formData.provider).then(models => {
      if (cancelled || models.length === 0) return;
      setProviderModels(prev => ({ ...prev, [formData.provider]: models }));
      setFormData(prev => models.includes(prev.model) ? prev : { ...prev, model: models[0] });
    });
    return () => { cancelled = true; };
  }, [formData.provider]);

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
      updateField('tools', [...preset.tools]);
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

  const handleSubmit = () => {
    onSave(formData);
  };

  return (
    <div className="max-w-4xl mx-auto">
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

      {/* Step Content */}
      <div className="bg-white rounded-xl border border-gray-200 p-8">
        {currentStep === 0 && (
          <BasicsStep formData={formData} updateField={updateField} providerModels={providerModels} />
        )}
        {currentStep === 1 && (
          <ConfigureStep
            formData={formData}
            meta={meta}
            toggleArrayItem={toggleArrayItem}
            updateField={updateField}
            selectPreset={selectPreset}
          />
        )}
        {currentStep === 2 && (
          <ReviewStep formData={formData} />
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

// Step 1: Basics
function BasicsStep({ formData, updateField, providerModels }) {
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
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Model</label>
            <select
              value={formData.model}
              onChange={(e) => updateField('model', e.target.value)}
              className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500"
            >
              {providerModels[formData.provider].map(model => (
                <option key={model} value={model}>{model}</option>
              ))}
            </select>
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
function ConfigureStep({ formData, meta, toggleArrayItem, updateField, selectPreset }) {
  const presets = Object.keys(AGENT_PRESETS);
  const allInstructions = Object.keys(INSTRUCTIONS);
  const allTools = Object.keys(TOOLS);

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

      {/* Tools - matching lander's chip selector */}
      <div>
        <label className="block text-sm font-medium text-gray-700 mb-3">
          <strong>Tools</strong>
          <span className="text-gray-400 font-normal ml-2">MCPs and integrations</span>
        </label>
        <div className="flex flex-wrap gap-2">
          {allTools.map(id => {
            const tool = TOOLS[id];
            return (
              <button
                key={id}
                onClick={() => toggleArrayItem('tools', id)}
                className={`flex items-center gap-1.5 px-3 py-1.5 rounded-full text-sm transition-colors ${
                  formData.tools.includes(id)
                    ? 'bg-red-500 text-white'
                    : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                }`}
              >
                <span>{tool.emoji}</span>
                <span>{tool.label}</span>
              </button>
            );
          })}
        </div>
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
function ReviewStep({ formData }) {
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
                formData.tools.map(id => {
                  const tool = TOOLS[id];
                  return tool ? (
                    <span key={id} className="px-2 py-0.5 bg-red-100 text-red-700 rounded text-xs">
                      {tool.emoji} {tool.label}
                    </span>
                  ) : null;
                })
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
