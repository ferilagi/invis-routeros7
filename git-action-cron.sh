#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "🔍 Checking for RouterOS updates via RSS feed..."

# Function to get version from RSS - HANYA OUTPUT VERSION
get_latest_from_rss() {
    local rss_url="https://cdn.mikrotik.com/routeros/latest-stable.rss"
    local rss

    rss=$(curl -fsSL \
        --retry 3 \
        --retry-delay 2 \
        --max-time 10 \
        "$rss_url") || return 1

    echo "$rss" \
      | sed -n 's|.*<link>https://mikrotik.com/download?v=\([0-9.]\+\)</link>.*|\1|p' \
      | head -n 1
}

# Debug info terpisah
echo "Trying RSS feed method..."
echo "Fetching from: https://cdn.mikrotik.com/routeros/latest-stable.rss"

# Get version - redirect debug ke stderr
set +e
VERSION=$(get_latest_from_rss)
RSS_EXIT_CODE=$?
set -e

echo "RSS function exit code: $RSS_EXIT_CODE"
echo "Extracted version raw: '$VERSION'"

# 0  = no update
# 10 = updated successfully
# 20 = soft failure (RSS, invalid data)
# 1  = hard failure
if [[ $RSS_EXIT_CODE -ne 0 || -z "$VERSION" ]]; then
    echo "❌ Failed to fetch version from RSS"
    exit 20
fi

echo ""
echo "=== VERSION VALIDATION ==="

# Clean version - hapus whitespace/newlines
VERSION=$(echo "$VERSION" | tr -d '[:space:]')

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "❌ Invalid version format: $VERSION"
    exit 20
fi

echo "✅ Version validated: $VERSION"

# Check current version in Dockerfile
echo ""
echo "=== DOCKERFILE CHECK ==="
if [[ ! -f "Dockerfile" ]]; then
    echo "❌ Dockerfile not found"
    exit 1
fi
echo "Dockerfile exists"

CURRENT=$(grep 'ARG ROUTEROS_VERSION=' Dockerfile | cut -d'"' -f2)

if [[ -z "$CURRENT" ]]; then
    echo "❌ Could not find ROUTEROS_VERSION in Dockerfile"
    exit 1
fi

echo ""
echo "=== VERSION COMPARISON ==="
echo "Latest from RSS: $VERSION"
echo "Current in Dockerfile: $CURRENT"

if [[ "$VERSION" == "$CURRENT" ]]; then
    echo "✅ Already up to date"
    exit 0
fi

echo "🔄 Update available: $CURRENT → $VERSION"

# Continue with update...
echo "📝 Updating Dockerfile..."
sed -i.bak "s/ARG ROUTEROS_VERSION=\".*\"/ARG ROUTEROS_VERSION=\"$VERSION\"/" Dockerfile

# Verify the update
NEW_VERSION=$(grep 'ARG ROUTEROS_VERSION=' Dockerfile | cut -d'"' -f2)
[[ "$NEW_VERSION" == "$VERSION" ]] || exit 1
echo "✅ Dockerfile updated to $VERSION"

update_readme() {
    local version="$1"
    local readme_file="README.md"
    
    if [[ -f "$readme_file" ]]; then
        echo "Updating version in README.md..."
        # Update version badges atau info di README
        sed -i "s/routeros-[0-9]*\.[0-9]*\.[0-9]*-blue/routeros-$version-blue/g" "$readme_file" 2>/dev/null || true
        sed -i "s/Version:.*$/Version: $version/g" "$readme_file" 2>/dev/null || true
        git add "$readme_file" 2>/dev/null || true
    fi
}

# Update README
update_readme "$VERSION"

# Setup Git
git config --global user.name "GitHub Actions"
git config --global user.email "actions@github.com"

# Commit changes
echo "Committing changes..."
git add Dockerfile README.md 2>/dev/null || git add Dockerfile

git diff --cached --quiet && {
    echo "⚠️ No changes to commit"
    exit 0
}

git commit -m "chore: update RouterOS to $VERSION" \
           -m "Automated update from $CURRENT to $VERSION"
echo "✓ Changes committed"

# Push changes
echo "Pushing to main branch..."
git push origin main
echo "✓ Main branch updated"

# Create and push tag
echo "Creating tag v$VERSION..."
git tag -a "v$VERSION" -m "RouterOS $VERSION" || true
git push origin "v$VERSION" || true

# Cleanup
rm -f Dockerfile.bak

echo "✅ Update completed successfully!"
echo "📦 New version: $VERSION"