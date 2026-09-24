import React, { useId } from 'react';

// Model field for the agent builder/editor. A text input over a <datalist>
// rather than a <select>: provider catalogs run to hundreds of models
// (OpenRouter), and typing filters them, so every model stays reachable
// without scrolling a fixed list. Any model id may also be typed outright —
// one the catalog doesn't list yet, or a locally pulled Ollama model.
export default function ModelPicker({ value, models = [], onChange, className, style }) {
  const listId = useId();

  return (
    <>
      <input
        type="text"
        list={listId}
        value={value || ''}
        onChange={(e) => onChange(e.target.value)}
        placeholder="Type to search models"
        autoComplete="off"
        spellCheck={false}
        className={className}
        style={style}
      />
      <datalist id={listId}>
        {models.filter(Boolean).map(m => (
          <option key={m} value={m} />
        ))}
      </datalist>
    </>
  );
}
