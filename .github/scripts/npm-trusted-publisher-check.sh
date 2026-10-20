#!/usr/bin/env bash
# Fails, with the registry's reason, when this GitHub Actions job cannot
# exchange its OIDC token for an npm token for the package. npm makes the
# same exchange itself on publish, but on failure it logs the reason only at
# --loglevel verbose and carries on without a token, so the publish dies with
# a bare E401 that names neither the registry's reason nor the claims it saw.
#
#   .github/scripts/npm-trusted-publisher-check.sh @activeagents/browser-sidecar
#
# Needs `permissions: id-token: write` on the job.
set -euo pipefail

package="${1:?the package name}"
registry="https://registry.npmjs.org"

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  echo "::error::No OIDC token is available to this job; it needs permissions: id-token: write."
  exit 1
fi

id_token="$(curl -fsS -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=npm:registry.npmjs.org" | jq -r '.value // empty')"
if [ -z "$id_token" ]; then
  echo "::error::GitHub returned no OIDC token for the npm audience."
  exit 1
fi
echo "::add-mask::${id_token}"

escaped="$(node -p 'encodeURIComponent(process.argv[1]).replace("%40", "@")' "$package")"
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
status="$(curl -sS -o "$body" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer ${id_token}" -H "Content-Type: application/json" \
  "${registry}/-/npm/v1/oidc/token/exchange/package/${escaped}")"

case "$status" in
  2??)
    echo "This job is a trusted publisher of ${package}."
    exit 0
    ;;
esac

# The claims are what the trusted publisher on npmjs.com is matched against:
# the repository, the workflow file in workflow_ref, and the environment.
claims="$(node -e '
  const p = JSON.parse(Buffer.from(process.argv[1].split(".")[1], "base64url").toString())
  for (const k of ["repository", "repository_owner", "workflow_ref", "ref", "environment"])
    console.log(`  ${k}: ${p[k] ?? "(none)"}`)
' "$id_token")"
echo "::error::npm refused the trusted publishing exchange for ${package} (HTTP ${status}): $(jq -r '.message // .error // empty' "$body" 2>/dev/null || cat "$body")"
echo "The trusted publisher on npmjs.com (package Settings → Trusted publishing) must match these claims:"
echo "$claims"
exit 1
