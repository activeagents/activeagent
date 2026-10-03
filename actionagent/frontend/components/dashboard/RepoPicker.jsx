import React from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { filterRepositories } from '../../utils/repositories.mjs';

// A filterable checklist of repositories, selected by full name.
//
// repositories: [{ id, full_name, private }], as GET
//   /api/github_connection/repositories lists them.
// selection: the Set of selected full names; onToggle(fullName) flips one.
// filter / onFilterChange: the filter text, held by the caller so it
//   survives the picker closing and reopening.
export default function RepoPicker({ repositories, selection, onToggle, filter, onFilterChange }) {
  const { darkMode } = useTheme();
  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const strong = darkMode ? 'text-white' : 'text-gray-900';
  const rowStyle = { backgroundColor: darkMode ? '#252525' : '#f9fafb' };
  const visible = filterRepositories(repositories, filter);

  return (
    <div className="space-y-2">
      <input
        type="text"
        value={filter}
        onChange={(e) => onFilterChange(e.target.value)}
        placeholder="Filter repositories"
        className={`w-full px-3 py-2 border rounded-lg text-sm ${darkMode ? 'bg-gray-800 border-gray-700 text-white placeholder-gray-500' : 'bg-white border-gray-300 text-gray-900'}`}
      />
      <div className="max-h-80 overflow-y-auto space-y-1">
        {visible.map((repo) => (
          <label key={repo.id} className="flex items-center space-x-3 p-2 rounded cursor-pointer" style={rowStyle}>
            <input type="checkbox" checked={selection.has(repo.full_name)} onChange={() => onToggle(repo.full_name)} />
            <span className={`text-sm font-mono ${strong}`}>{repo.full_name}</span>
            {repo.private && <span className={`text-xs ${muted}`}>private</span>}
          </label>
        ))}
        {visible.length === 0 && <p className={`text-sm ${muted}`}>No repositories match.</p>}
      </div>
    </div>
  );
}
