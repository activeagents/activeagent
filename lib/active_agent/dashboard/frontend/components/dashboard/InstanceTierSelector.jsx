import React, { useState, useEffect } from 'react';
import { TYPOGRAPHY } from '../../utils/designTokens';

/**
 * Instance Tier Selector
 *
 * Allows users to select hardware configuration for sandbox sessions.
 * Similar to Google Colab or HuggingFace Spaces hardware selection.
 *
 * Usage:
 *   <InstanceTierSelector
 *     selectedTier={tier}
 *     onSelect={(tier) => setTier(tier)}
 *     sandboxType="playwright_mcp"
 *   />
 */
export default function InstanceTierSelector({
  selectedTier,
  onSelect,
  sandboxType = 'default',
  showPricing = true,
  compact = false
}) {
  const [tiers, setTiers] = useState([]);
  const [recommended, setRecommended] = useState(null);
  const [loading, setLoading] = useState(true);
  const [activeCategory, setActiveCategory] = useState('all');

  useEffect(() => {
    loadTiers();
    loadRecommendation();
  }, [sandboxType]);

  const loadTiers = async () => {
    try {
      const response = await fetch('/api/instance_tiers');
      const data = await response.json();
      setTiers(data.tiers);
    } catch (error) {
      console.error('Failed to load instance tiers:', error);
    } finally {
      setLoading(false);
    }
  };

  const loadRecommendation = async () => {
    try {
      const response = await fetch(`/api/instance_tiers/recommend?sandbox_type=${sandboxType}`);
      const data = await response.json();
      setRecommended(data.recommended);

      // Auto-select recommended if no tier selected
      if (!selectedTier && data.recommended) {
        onSelect(data.recommended);
      }
    } catch (error) {
      console.error('Failed to load recommendation:', error);
    }
  };

  const filteredTiers = activeCategory === 'all'
    ? tiers
    : activeCategory === 'gpu'
      ? tiers.filter(t => t.specs.gpu)
      : tiers.filter(t => t.category === activeCategory && !t.specs.gpu);

  const categories = [
    { id: 'all', label: 'All' },
    { id: 'free', label: 'Free' },
    { id: 'pro', label: 'Pro' },
    { id: 'gpu', label: 'GPU' }
  ];

  if (loading) {
    return (
      <div className="animate-pulse space-y-3">
        <div className="h-8 bg-gray-200 rounded w-1/3"></div>
        <div className="grid grid-cols-2 gap-3">
          {[1, 2, 3, 4].map(i => (
            <div key={i} className="h-24 bg-gray-200 rounded-lg"></div>
          ))}
        </div>
      </div>
    );
  }

  if (compact) {
    return (
      <CompactSelector
        tiers={tiers}
        selectedTier={selectedTier}
        recommended={recommended}
        onSelect={onSelect}
        showPricing={showPricing}
      />
    );
  }

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex items-center justify-between">
        <h3 className="text-lg font-semibold text-gray-900">Select Hardware</h3>
        {recommended && (
          <span className="text-sm text-gray-500">
            Recommended for {sandboxType.replace('_', ' ')}
          </span>
        )}
      </div>

      {/* Category Tabs */}
      <div className="flex space-x-2 border-b border-gray-200">
        {categories.map(cat => (
          <button
            key={cat.id}
            onClick={() => setActiveCategory(cat.id)}
            className={`px-4 py-2 text-sm font-medium border-b-2 transition-colors ${
              activeCategory === cat.id
                ? 'border-emerald-500 text-emerald-600'
                : 'border-transparent text-gray-500 hover:text-gray-700'
            }`}
          >
            {cat.label}
          </button>
        ))}
      </div>

      {/* Tier Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {filteredTiers.map(tier => (
          <TierCard
            key={tier.id}
            tier={tier}
            isSelected={selectedTier?.id === tier.id}
            isRecommended={recommended?.id === tier.id}
            onSelect={() => onSelect(tier)}
            showPricing={showPricing}
          />
        ))}
      </div>

      {/* Selection Summary */}
      {selectedTier && (
        <div className="p-4 bg-gray-50 rounded-lg border border-gray-200">
          <div className="flex items-center justify-between">
            <div>
              <span className="text-sm text-gray-500">Selected: </span>
              <span className="font-medium text-gray-900">{selectedTier.name}</span>
            </div>
            {showPricing && (
              <div className="text-right">
                <span className="text-lg font-semibold text-gray-900">
                  {selectedTier.pricing.display}
                </span>
                {selectedTier.pricing.hourly_cost > 0 && (
                  <span className="text-sm text-gray-500 ml-2">
                    (~${(selectedTier.pricing.hourly_cost * 24 * 30).toFixed(0)}/mo)
                  </span>
                )}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

/**
 * Individual tier card
 */
function TierCard({ tier, isSelected, isRecommended, onSelect, showPricing }) {
  const hasGpu = tier.specs.gpu;

  return (
    <button
      onClick={onSelect}
      className={`relative p-4 rounded-xl border-2 text-left transition-all ${
        isSelected
          ? 'border-emerald-500 bg-emerald-50 ring-2 ring-emerald-200'
          : 'border-gray-200 hover:border-gray-300 hover:shadow-sm'
      }`}
    >
      {/* Badges */}
      <div className="absolute -top-2 -right-2 flex space-x-1">
        {isRecommended && (
          <span className="px-2 py-0.5 text-xs font-medium bg-emerald-500 text-white rounded-full">
            Recommended
          </span>
        )}
        {tier.category === 'free' && (
          <span className="px-2 py-0.5 text-xs font-medium bg-blue-500 text-white rounded-full">
            Free
          </span>
        )}
      </div>

      {/* Tier Name */}
      <div className="flex items-center space-x-2 mb-2">
        <span className="text-lg font-semibold text-gray-900">{tier.name}</span>
        {hasGpu && (
          <span
            className="px-1.5 py-0.5 text-xs font-mono bg-purple-100 text-purple-700 rounded"
            style={{ fontFamily: TYPOGRAPHY.mono }}
          >
            GPU
          </span>
        )}
      </div>

      {/* Specs */}
      <div className="space-y-1 text-sm text-gray-600 mb-3">
        <div className="flex items-center space-x-2">
          <span style={{ fontFamily: TYPOGRAPHY.mono }}>[CPU]</span>
          <span>{tier.specs.cpu_cores} vCPU</span>
        </div>
        <div className="flex items-center space-x-2">
          <span style={{ fontFamily: TYPOGRAPHY.mono }}>[RAM]</span>
          <span>{tier.specs.memory_gb}GB</span>
        </div>
        {hasGpu && (
          <div className="flex items-center space-x-2">
            <span style={{ fontFamily: TYPOGRAPHY.mono }}>[GPU]</span>
            <span>{tier.specs.gpu_memory_gb}GB {formatGpuName(tier.specs.gpu)}</span>
          </div>
        )}
        <div className="flex items-center space-x-2">
          <span style={{ fontFamily: TYPOGRAPHY.mono }}>[DSK]</span>
          <span>{tier.specs.disk_gb}GB SSD</span>
        </div>
      </div>

      {/* Pricing */}
      {showPricing && (
        <div className="pt-2 border-t border-gray-200">
          <span className={`text-lg font-bold ${
            tier.pricing.hourly_cost === 0 ? 'text-blue-600' : 'text-gray-900'
          }`}>
            {tier.pricing.display}
          </span>
        </div>
      )}

      {/* Selection Indicator */}
      {isSelected && (
        <div className="absolute bottom-2 right-2">
          <span
            className="text-emerald-500"
            style={{ fontFamily: TYPOGRAPHY.mono }}
          >
            [*]
          </span>
        </div>
      )}
    </button>
  );
}

/**
 * Compact dropdown selector
 */
function CompactSelector({ tiers, selectedTier, recommended, onSelect, showPricing }) {
  const [isOpen, setIsOpen] = useState(false);

  return (
    <div className="relative">
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="w-full flex items-center justify-between px-4 py-3 border border-gray-300 rounded-lg bg-white hover:bg-gray-50 transition-colors"
      >
        <div className="flex items-center space-x-3">
          <span style={{ fontFamily: TYPOGRAPHY.mono }} className="text-gray-400">
            [HW]
          </span>
          <div className="text-left">
            <div className="font-medium text-gray-900">
              {selectedTier?.name || 'Select Hardware'}
            </div>
            {selectedTier && (
              <div className="text-xs text-gray-500">
                {selectedTier.specs.cpu_cores} vCPU | {selectedTier.specs.memory_gb}GB RAM
                {selectedTier.specs.gpu && ` | ${formatGpuName(selectedTier.specs.gpu)}`}
              </div>
            )}
          </div>
        </div>
        <div className="flex items-center space-x-2">
          {showPricing && selectedTier && (
            <span className="text-sm font-medium text-gray-600">
              {selectedTier.pricing.display}
            </span>
          )}
          <span style={{ fontFamily: TYPOGRAPHY.mono }} className="text-gray-400">
            {isOpen ? '[^]' : '[v]'}
          </span>
        </div>
      </button>

      {isOpen && (
        <div className="absolute z-10 w-full mt-1 bg-white border border-gray-200 rounded-lg shadow-lg max-h-96 overflow-auto">
          {tiers.map(tier => (
            <button
              key={tier.id}
              onClick={() => {
                onSelect(tier);
                setIsOpen(false);
              }}
              className={`w-full flex items-center justify-between px-4 py-3 hover:bg-gray-50 transition-colors ${
                selectedTier?.id === tier.id ? 'bg-emerald-50' : ''
              }`}
            >
              <div className="flex items-center space-x-3">
                <div className="text-left">
                  <div className="flex items-center space-x-2">
                    <span className="font-medium text-gray-900">{tier.name}</span>
                    {tier.specs.gpu && (
                      <span className="px-1 text-xs bg-purple-100 text-purple-700 rounded">GPU</span>
                    )}
                    {recommended?.id === tier.id && (
                      <span className="px-1 text-xs bg-emerald-100 text-emerald-700 rounded">Rec</span>
                    )}
                  </div>
                  <div className="text-xs text-gray-500">
                    {tier.specs.cpu_cores} vCPU | {tier.specs.memory_gb}GB
                    {tier.specs.gpu && ` | ${tier.specs.gpu_memory_gb}GB VRAM`}
                  </div>
                </div>
              </div>
              <div className="flex items-center space-x-2">
                <span className={`text-sm font-medium ${
                  tier.pricing.hourly_cost === 0 ? 'text-blue-600' : 'text-gray-600'
                }`}>
                  {tier.pricing.display}
                </span>
                {selectedTier?.id === tier.id && (
                  <span style={{ fontFamily: TYPOGRAPHY.mono }} className="text-emerald-500">
                    [*]
                  </span>
                )}
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/**
 * Format GPU name for display
 */
function formatGpuName(gpuId) {
  if (!gpuId) return '';

  const names = {
    'nvidia-tesla-t4': 'T4',
    'nvidia-l4': 'L4',
    'nvidia-a10g': 'A10G',
    'nvidia-a100-40gb': 'A100 40GB',
    'nvidia-a100-80gb': 'A100 80GB'
  };

  return names[gpuId] || gpuId.replace('nvidia-', '').toUpperCase();
}
