#!/usr/bin/env bash
# Fails when browser-sidecar/ packs differently from the version of
# @activeagents/browser-sidecar already on npm: a published version is never
# published again, so a sidecar change needs a new version.
#
#   .github/scripts/browser-sidecar-unchanged.sh browser-sidecar 1.9.0
set -euo pipefail

dir="$(cd "${1:?the sidecar directory}" && pwd)"
version="${2:?the version on npm}"
package="@activeagents/browser-sidecar@${version}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/published" "$work/repo"

# Both tarballs share a file name, so each is packed into its own directory.
published="$(cd "$work/published" && npm pack "$package" --silent)"
repo="$(cd "$dir" && npm pack --silent --pack-destination "$work/repo")"
tar -xzf "$work/published/$published" -C "$work/published"
tar -xzf "$work/repo/$repo" -C "$work/repo"

if ! diff -r "$work/published/package" "$work/repo/package" > "$work/diff.txt"; then
  echo "::error::browser-sidecar changed since ${package} was published; bump the version (browser-sidecar/package.json and ActionAgent::VERSION)."
  head -n 80 "$work/diff.txt"
  exit 1
fi
echo "browser-sidecar matches ${package} on npm."
