import React, { useId } from 'react';

// A model field. It is a text input over a <datalist> rather than a <select>
// because provider catalogs run to hundreds of models (OpenRouter), and typing
// filters them, so every model stays reachable without scrolling a fixed list.
// Any model id may also be typed outright — one the catalog doesn't list yet,
// or a locally pulled Ollama model.
//
// `onChange` receives the value and the change event. Props beyond those
// listed (id, onKeyDown, onBlur, aria-*) go to the input.
export default function ModelPicker({
  value, models = [], onChange, className, style, placeholder = 'Type to search models', inputRef, ...inputProps
}) {
  const listId = useId();

  return (
    <>
      <input
        {...inputProps}
        ref={inputRef}
        type="text"
        list={listId}
        value={value || ''}
        onChange={(e) => onChange(e.target.value, e)}
        placeholder={placeholder}
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
