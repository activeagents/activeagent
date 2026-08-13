import React, { useState, useEffect } from 'react';
import AgentAvatar from '../AgentAvatar';

const CATEGORY_ICONS = {
  productivity: '[+]',
  development: '<>',
  research: '[?]',
  creative: '[*]',
  data: '[#]',
  automation: '[>]'
};

export default function TemplateLibrary({ onUseTemplate, onClose }) {
  const [templates, setTemplates] = useState([]);
  const [categories, setCategories] = useState([]);
  const [selectedCategory, setSelectedCategory] = useState('');
  const [selectedTemplate, setSelectedTemplate] = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isCreating, setIsCreating] = useState(false);

  useEffect(() => {
    loadTemplates();
  }, [selectedCategory]);

  const loadTemplates = async () => {
    setIsLoading(true);
    try {
      const params = new URLSearchParams();
      if (selectedCategory) params.append('category', selectedCategory);

      const response = await fetch(`/api/templates?${params}`);
      const data = await response.json();
      setTemplates(data.templates);
      setCategories(data.categories);
    } catch (error) {
      console.error('Failed to load templates:', error);
    } finally {
      setIsLoading(false);
    }
  };

  const handleUseTemplate = async (template) => {
    setIsCreating(true);
    try {
      const response = await fetch(`/api/templates/${template.id}/use`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: template.name })
      });

      if (response.ok) {
        const data = await response.json();
        onUseTemplate(data.agent);
      }
    } catch (error) {
      console.error('Failed to create agent from template:', error);
    } finally {
      setIsCreating(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
      <div className="bg-white rounded-2xl w-full max-w-5xl max-h-[90vh] flex flex-col overflow-hidden">
        {/* Header */}
        <div className="px-6 py-4 border-b border-gray-200 flex items-center justify-between">
          <div>
            <h2 className="text-xl font-semibold text-gray-900">Template Library</h2>
            <p className="text-sm text-gray-500">Start with a pre-configured agent template</p>
          </div>
          <button
            onClick={onClose}
            className="p-2 text-gray-400 hover:text-gray-600 transition-colors"
          >
            <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Content */}
        <div className="flex-1 flex overflow-hidden">
          {/* Category Sidebar */}
          <div className="w-48 border-r border-gray-200 p-4 flex-shrink-0">
            <h3 className="text-xs font-semibold text-gray-400 uppercase mb-3">Categories</h3>
            <div className="space-y-1">
              <button
                onClick={() => setSelectedCategory('')}
                className={`w-full text-left px-3 py-2 rounded-lg text-sm transition-colors ${
                  !selectedCategory ? 'bg-red-50 text-red-600' : 'text-gray-600 hover:bg-gray-50'
                }`}
              >
                All Templates
              </button>
              {categories.map(cat => (
                <button
                  key={cat}
                  onClick={() => setSelectedCategory(cat)}
                  className={`w-full text-left px-3 py-2 rounded-lg text-sm flex items-center space-x-2 transition-colors ${
                    selectedCategory === cat ? 'bg-red-50 text-red-600' : 'text-gray-600 hover:bg-gray-50'
                  }`}
                >
                  <span>{CATEGORY_ICONS[cat] || '📦'}</span>
                  <span className="capitalize">{cat}</span>
                </button>
              ))}
            </div>
          </div>

          {/* Template Grid */}
          <div className="flex-1 p-6 overflow-auto">
            {isLoading ? (
              <div className="flex items-center justify-center h-full">
                <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-red-500"></div>
              </div>
            ) : templates.length > 0 ? (
              <div className="grid grid-cols-2 lg:grid-cols-3 gap-4">
                {templates.map(template => {
                  return (
                    <div
                      key={template.id}
                      onClick={() => setSelectedTemplate(template)}
                      className={`bg-white rounded-xl border-2 p-4 cursor-pointer transition-all hover:shadow-lg ${
                        selectedTemplate?.id === template.id
                          ? 'border-red-500 ring-2 ring-red-100'
                          : 'border-gray-200 hover:border-gray-300'
                      }`}
                    >
                      <div className="flex items-start space-x-3">
                        <div className="flex-shrink-0">
                          <AgentAvatar size={60} />
                        </div>
                        <div className="flex-1 min-w-0">
                          <div className="flex items-center space-x-2">
                            <span className="text-lg">{template.icon}</span>
                            <h3 className="font-medium text-gray-900 truncate">{template.name}</h3>
                          </div>
                          <p className="text-xs text-gray-500 mt-1 line-clamp-2">{template.description}</p>
                          <div className="flex items-center space-x-2 mt-2">
                            <span className="text-xs px-2 py-0.5 bg-gray-100 rounded capitalize">{template.category}</span>
                            {template.featured && (
                              <span className="text-xs px-2 py-0.5 bg-yellow-100 text-yellow-700 rounded">Featured</span>
                            )}
                          </div>
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            ) : (
              <div className="text-center py-12 text-gray-500">
                No templates found in this category
              </div>
            )}
          </div>

          {/* Template Detail */}
          {selectedTemplate && (
            <div className="w-80 border-l border-gray-200 p-6 flex-shrink-0 bg-gray-50 overflow-auto">
              <div className="flex justify-center mb-4">
                <AgentAvatar size={120} />
              </div>

              <h3 className="text-lg font-semibold text-gray-900 text-center">{selectedTemplate.name}</h3>
              <p className="text-sm text-gray-500 text-center mt-1">{selectedTemplate.description}</p>

              <div className="mt-6 space-y-4">
                <div>
                  <span className="text-xs font-medium text-gray-500 uppercase">Provider / Model</span>
                  <p className="text-sm text-gray-900">{selectedTemplate.provider} / {selectedTemplate.model}</p>
                </div>

                {selectedTemplate.tools?.length > 0 && (
                  <div>
                    <span className="text-xs font-medium text-gray-500 uppercase">Tools</span>
                    <div className="flex flex-wrap gap-1 mt-1">
                      {selectedTemplate.tools.map(tool => (
                        <span key={tool} className="text-xs px-2 py-0.5 bg-red-100 text-red-700 rounded">{tool}</span>
                      ))}
                    </div>
                  </div>
                )}

                <div>
                  <span className="text-xs font-medium text-gray-500 uppercase">Usage</span>
                  <p className="text-sm text-gray-900">{selectedTemplate.usage_count} agents created</p>
                </div>
              </div>

              <button
                onClick={() => handleUseTemplate(selectedTemplate)}
                disabled={isCreating}
                className="w-full mt-6 px-4 py-2 bg-red-500 text-white rounded-lg hover:bg-red-600 transition-colors disabled:opacity-50"
              >
                {isCreating ? 'Creating...' : 'Use This Template'}
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
