import React, { useId, useRef, useState } from 'react';
import ModelPicker from './ModelPicker';
import { MONO } from './primitives';
import {
  appendModels, draftKeyAction, isSuggestionPick, parseModelList, serializeModelList, splitDraft,
} from '../../utils/modelOptions.mjs';

// A field for several models: each chosen model is a chip with a remove
// button, and a ModelPicker after them searches the catalog for the next.
// `value` and `onChange` carry the comma-separated list the evaluation forms
// submit.
//
// A picked suggestion is added at once. Typed text is added on Enter, on a
// comma, or when the field loses focus, so a model the catalog lacks can be
// added too. Backspace in the empty field removes the last model. `style` is
// the field's own look: the wrapper carries its border, padding and
// background, and the input inside inherits its font and color.
//
// `title` is the input's tooltip, and is read to screen readers along with
// the field's hint (`describedBy`, the id of text the form renders) and the
// models already chosen. Adding or removing a model is announced.
export default function MultiModelPicker({
  value, onChange, models = [], placeholder, style, title, describedBy, inputId, inputLabel, testId,
}) {
  const [draft, setDraft] = useState('');
  const [announcement, setAnnouncement] = useState('');
  const inputRef = useRef(null);
  const ids = useId();
  const selected = parseModelList(value);
  // The list as last rendered, for a commit that runs after this render's
  // handlers were bound: a deferred Enter, or focus leaving the field just
  // ahead of a click.
  const latest = useRef(selected);
  latest.current = selected;

  const commit = (text) => {
    const next = appendModels(latest.current, text);
    if (next.length !== latest.current.length) {
      onChange(serializeModelList(next));
      setAnnouncement(`Added ${next.slice(latest.current.length).join(', ')}`);
    }
    setDraft('');
  };

  const remove = (model) => {
    onChange(serializeModelList(latest.current.filter((m) => m !== model)));
    setAnnouncement(`Removed ${model}`);
    inputRef.current?.focus();
  };

  const handleChange = (text, event) => {
    if (text.includes(',')) {
      const { complete, rest } = splitDraft(text);
      commit(complete);
      setDraft(rest);
    } else if (isSuggestionPick(event.nativeEvent?.inputType, text, models)) {
      commit(text);
    } else {
      setDraft(text.trimStart());
    }
  };

  const handleKeyDown = (event) => {
    const action = draftKeyAction(event, draft, latest.current.length);
    if (action === 'commit') {
      event.preventDefault();
      // Read the field once the key has been handled: a browser that applies
      // a highlighted suggestion after keydown has replaced the text by then.
      setTimeout(() => commit(inputRef.current?.value || ''), 0);
    } else if (action === 'removeLast') {
      event.preventDefault();
      remove(latest.current[latest.current.length - 1]);
    }
  };

  const available = models.filter((m) => !selected.includes(m));
  const describedByIds = [describedBy, title && `${ids}-title`, `${ids}-selected`].filter(Boolean).join(' ');

  return (
    <div
      data-testid={testId}
      onClick={(e) => { if (e.target === e.currentTarget) inputRef.current?.focus(); }}
      style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 4, cursor: 'text', ...style }}
    >
      {selected.map((model) => (
        <span key={model} style={chipStyle}>
          <span style={{ overflowWrap: 'anywhere' }}>{model}</span>
          <button
            type="button"
            onClick={() => remove(model)}
            aria-label={`Remove ${model}`}
            title={`Remove ${model}`}
            style={removeStyle}
          >
            ×
          </button>
        </span>
      ))}
      <ModelPicker
        inputRef={inputRef}
        id={inputId}
        aria-label={inputLabel}
        aria-describedby={describedByIds}
        title={title}
        value={draft}
        models={available}
        onChange={handleChange}
        onKeyDown={handleKeyDown}
        onBlur={() => { if (draft.trim()) commit(draft); }}
        placeholder={selected.length ? 'Add a model' : placeholder}
        style={{ flex: '1 1 80px', minWidth: 80, padding: 0, border: 'none', background: 'transparent', font: 'inherit', color: 'inherit' }}
      />
      {title && <span id={`${ids}-title`} style={visuallyHidden}>{title}</span>}
      <span id={`${ids}-selected`} style={visuallyHidden}>
        {selected.length ? `Chosen: ${selected.join(', ')}` : 'No models chosen'}
      </span>
      <span role="status" aria-live="polite" style={visuallyHidden}>{announcement}</span>
    </div>
  );
}

const chipStyle = {
  display: 'inline-flex', alignItems: 'center', gap: 2, maxWidth: '100%', padding: '0 2px 0 8px', borderRadius: 999,
  fontFamily: MONO, fontSize: 11, lineHeight: '18px',
  background: 'var(--color-muted)', border: '1px solid var(--color-border)', color: 'var(--color-text-primary)',
};

const removeStyle = {
  padding: '0 5px', border: 'none', borderRadius: 999, background: 'transparent', cursor: 'pointer',
  fontSize: 13, lineHeight: '18px', color: 'var(--color-text-muted)',
};

// Read by screen readers, not shown.
const visuallyHidden = {
  position: 'absolute', width: 1, height: 1, padding: 0, margin: -1, overflow: 'hidden',
  clip: 'rect(0 0 0 0)', whiteSpace: 'nowrap', border: 0,
};
