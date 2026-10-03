import React, { useEffect, useState } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { filterRepositories } from '../../utils/repositories.mjs';
import { isRepositoryName } from '../../utils/projects.mjs';

// What the picker says in each state other than "ready" (see
// repoPickerState in utils/projects.mjs).
const STATE_MESSAGES = {
  loading: 'Loading repositories…',
  not_configured: 'GitHub is not configured on this dashboard.',
  not_connected: 'Connect GitHub to pick a repository.',
  reconnect_required: 'GitHub rejected the stored token. Reconnect GitHub to list repositories again.',
  pending_approval: 'The GitHub installation is waiting for an owner of the account to approve it. Check again once it is approved.',
  empty: 'This GitHub connection reaches no repositories yet.',
};

// A filterable list of repositories, chosen by full name.
//
// repositories: [{ id, full_name, private }], as GET
//   /api/github_connection/repositories lists them.
// filter / onFilterChange: the filter text, held by the caller so it
//   survives the picker closing and reopening.
//
// Two modes:
//   multiple (default)  checkboxes. selection: the Set of selected full
//                       names; onToggle(fullName) flips one.
//   single              one choice. selected: its full name; onSelect(fullName).
//
// Optional, for picking a project's repository:
//   state               see STATE_MESSAGES; "ready" lists the repositories
//   settingsHref        where GitHub is connected or reconnected
//   missingRepositoryUrl  where access to more repositories is granted. The
//                       "Repository not listed?" link opens it, and the list
//                       is fetched again (onRefresh) when the window regains
//                       focus.
//   onRefresh           fetches the list again
//   onTypeName(owner/name)  looks up a repository by name, for one past the
//                       listing's cap; typedNameError says why it failed
export default function RepoPicker({
  repositories, selection, onToggle, filter, onFilterChange,
  mode = 'multiple', selected = null, onSelect,
  state = 'ready', settingsHref, missingRepositoryUrl, onRefresh, onTypeName, typedNameError,
}) {
  const { darkMode } = useTheme();
  const [typedName, setTypedName] = useState('');
  const [awaitingReturn, setAwaitingReturn] = useState(false);
  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const strong = darkMode ? 'text-white' : 'text-gray-900';
  const rowStyle = { backgroundColor: darkMode ? '#252525' : '#f9fafb' };
  const inputClass = `w-full px-3 py-2 border rounded-lg text-sm ${darkMode ? 'bg-gray-800 border-gray-700 text-white placeholder-gray-500' : 'bg-white border-gray-300 text-gray-900'}`;
  const visible = filterRepositories(repositories, filter);

  // Back from GitHub's settings: whatever access was granted there shows up
  // in a fresh listing.
  useEffect(() => {
    if (!awaitingReturn || !onRefresh) return undefined;
    const refresh = () => {
      setAwaitingReturn(false);
      onRefresh();
    };
    window.addEventListener('focus', refresh);
    return () => window.removeEventListener('focus', refresh);
  }, [awaitingReturn, onRefresh]);

  const missingLink = missingRepositoryUrl ? (
    <a
      href={missingRepositoryUrl}
      target="_blank"
      rel="noreferrer"
      onClick={() => setAwaitingReturn(true)}
      className="text-sm underline"
      data-testid="repo-picker-missing"
    >
      Repository not listed?
    </a>
  ) : null;

  const typeName = onTypeName ? (
    <form
      className="flex items-center gap-2"
      onSubmit={(event) => {
        event.preventDefault();
        if (isRepositoryName(typedName)) onTypeName(typedName);
      }}
    >
      <input
        type="text"
        value={typedName}
        onChange={(event) => setTypedName(event.target.value.trim())}
        placeholder="Type owner/name"
        aria-label="Repository owner/name"
        className={inputClass}
        data-testid="repo-picker-typed-name"
      />
      <button type="submit" disabled={!isRepositoryName(typedName)} className={`px-3 py-2 border rounded-lg text-sm ${strong}`}>
        Look up
      </button>
    </form>
  ) : null;

  if (state !== 'ready') {
    const linksToSettings = ['not_connected', 'reconnect_required'].includes(state) && settingsHref;
    return (
      <div className="space-y-2" data-testid={`repo-picker-${state}`}>
        <p className={`text-sm ${muted}`}>{STATE_MESSAGES[state] || STATE_MESSAGES.loading}</p>
        {linksToSettings && (
          <a href={settingsHref} className="text-sm underline">
            {state === 'reconnect_required' ? 'Reconnect GitHub' : 'Connect GitHub'} in Settings → Integrations
          </a>
        )}
        {state === 'pending_approval' && onRefresh && (
          <button type="button" onClick={onRefresh} className={`px-3 py-2 border rounded-lg text-sm ${strong}`}>Check again</button>
        )}
        {state === 'empty' && missingLink}
        {state === 'empty' && typeName}
        {typedNameError && <p className="text-sm text-red-500">{typedNameError}</p>}
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <input
        type="text"
        value={filter}
        onChange={(e) => onFilterChange(e.target.value)}
        placeholder="Filter repositories"
        className={inputClass}
      />
      <div className="max-h-80 overflow-y-auto space-y-1">
        {visible.map((repo) => (
          <label key={repo.id} className="flex items-center space-x-3 p-2 rounded cursor-pointer" style={rowStyle}>
            {mode === 'single' ? (
              <input type="radio" name="repository" checked={selected === repo.full_name} onChange={() => onSelect(repo.full_name)} />
            ) : (
              <input type="checkbox" checked={selection.has(repo.full_name)} onChange={() => onToggle(repo.full_name)} />
            )}
            <span className={`text-sm font-mono ${strong}`}>{repo.full_name}</span>
            {repo.private && <span className={`text-xs ${muted}`}>private</span>}
          </label>
        ))}
        {visible.length === 0 && <p className={`text-sm ${muted}`}>No repositories match.</p>}
      </div>
      {(missingLink || typeName) && (
        <div className="space-y-2">
          {missingLink}
          {typeName}
          {typedNameError && <p className="text-sm text-red-500">{typedNameError}</p>}
        </div>
      )}
    </div>
  );
}
