#!/bin/bash
set -e

# Build versioned documentation for Active Agent
# Automatically discovers versions from git release tags

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$PROJECT_ROOT/docs"
OUTPUT_DIR="$DOCS_DIR/.vitepress/dist"
VERSIONS_FILE="$DOCS_DIR/.vitepress/versions.json"

echo "=== Building Active Agent Versioned Documentation ==="
echo "Project root: $PROJECT_ROOT"

# Get current version from lib/active_agent/version.rb
CURRENT_VERSION=$(grep -oP 'VERSION = "\K[^"]+' "$PROJECT_ROOT/lib/active_agent/version.rb" || echo "dev")
echo "Current version: $CURRENT_VERSION"

# Discover all release tags (excluding RC/pre-release for stable versions list)
# Format: v0.6.3, v1.0.0, etc.
echo ""
echo "=== Discovering versions from git tags ==="

# Get all version tags, sorted by version number (newest first)
# Include both stable and RC versions
ALL_TAGS=$(git tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' | sort -V -r)

# Separate stable versions (no rc/alpha/beta suffix) from pre-release
STABLE_TAGS=$(echo "$ALL_TAGS" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)
PRERELEASE_TAGS=$(echo "$ALL_TAGS" | grep -E 'rc|alpha|beta' || true)

echo "Found stable tags: $(echo $STABLE_TAGS | tr '\n' ' ')"
echo "Found pre-release tags: $(echo $PRERELEASE_TAGS | tr '\n' ' ')"

# Generate versions.json dynamically
echo ""
echo "=== Generating versions.json ==="

# Determine latest stable version
LATEST_STABLE=$(echo "$STABLE_TAGS" | head -1 | sed 's/^v//')

# Build JSON structure
cat > "$VERSIONS_FILE" << EOF
{
  "current": "$CURRENT_VERSION",
  "latest_stable": "$LATEST_STABLE",
  "versions": [
    {
      "version": "$CURRENT_VERSION",
      "label": "$CURRENT_VERSION (Latest)",
      "path": "/",
      "isLatest": true
    }
EOF

# Add previous stable versions (limit to last 3 major versions for now)
VERSION_COUNT=0
MAX_VERSIONS=5

for TAG in $STABLE_TAGS; do
  VERSION="${TAG#v}"

  # Skip if this is the current version (already added)
  if [ "$VERSION" = "$CURRENT_VERSION" ]; then
    continue
  fi

  # Limit number of versions
  VERSION_COUNT=$((VERSION_COUNT + 1))
  if [ $VERSION_COUNT -gt $MAX_VERSIONS ]; then
    break
  fi

  cat >> "$VERSIONS_FILE" << EOF
,
    {
      "version": "$VERSION",
      "label": "$VERSION",
      "path": "/v$VERSION/",
      "tag": "$TAG"
    }
EOF
done

# Close JSON
cat >> "$VERSIONS_FILE" << EOF

  ]
}
EOF

echo "Generated versions.json:"
cat "$VERSIONS_FILE"

# Clean previous builds
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Build current (main branch) docs
echo ""
echo "=== Building current (main) documentation ==="
cd "$PROJECT_ROOT"
npm run docs:build

echo "Main docs built to $OUTPUT_DIR"

# Build each tagged version
echo ""
echo "=== Building versioned documentation ==="

# Store current state
CURRENT_REF=$(git rev-parse HEAD)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
STASH_NEEDED=false

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
  echo "Stashing uncommitted changes..."
  git stash push -m "versioned-docs-build"
  STASH_NEEDED=true
fi

VERSION_COUNT=0
for TAG in $STABLE_TAGS; do
  VERSION="${TAG#v}"

  # Skip current version
  if [ "$VERSION" = "$CURRENT_VERSION" ]; then
    continue
  fi

  # Limit versions
  VERSION_COUNT=$((VERSION_COUNT + 1))
  if [ $VERSION_COUNT -gt $MAX_VERSIONS ]; then
    break
  fi

  VERSION_OUTPUT_DIR="$OUTPUT_DIR/v$VERSION"

  echo ""
  echo "--- Building docs for $TAG ---"

  # Checkout the tag
  git checkout "$TAG" --quiet

  # Install dependencies
  npm ci --quiet 2>/dev/null || npm install --quiet

  # Check if this version has VitePress docs
  if [ ! -f "$DOCS_DIR/.vitepress/config.mts" ] && [ ! -f "$DOCS_DIR/.vitepress/config.mjs" ]; then
    echo "Warning: $TAG does not have VitePress config, skipping"
    continue
  fi

  # Run tests to generate doc examples if available
  if [ -f "Gemfile" ] && [ -f "bin/test" ]; then
    echo "Installing Ruby dependencies and running tests for $TAG..."
    bundle install --quiet 2>/dev/null || true
    RAILS_ENV=test bin/test 2>/dev/null || echo "Tests completed"
  fi

  # Build docs with versioned base path
  echo "Building VitePress docs for $TAG..."

  # Use environment variable or inline config for base path
  VITEPRESS_BASE="/v$VERSION/" npx vitepress build docs --outDir ".vitepress/dist-temp"

  # Move to final location
  mkdir -p "$VERSION_OUTPUT_DIR"
  if [ -d "$DOCS_DIR/.vitepress/dist-temp" ]; then
    cp -r "$DOCS_DIR/.vitepress/dist-temp/"* "$VERSION_OUTPUT_DIR/"
    rm -rf "$DOCS_DIR/.vitepress/dist-temp"
  fi

  echo "Built $TAG docs to $VERSION_OUTPUT_DIR"
done

# Return to original state
echo ""
echo "=== Returning to original branch ==="
git checkout "$CURRENT_BRANCH" --quiet 2>/dev/null || git checkout "$CURRENT_REF" --quiet

if [ "$STASH_NEEDED" = true ]; then
  echo "Restoring stashed changes..."
  git stash pop --quiet
fi

# Reinstall current dependencies
npm ci --quiet

echo ""
echo "=== Build complete ==="
echo "Output directory: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
