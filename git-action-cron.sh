#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Function to get latest versions
get_latest_versions() {
    local url="$1"
    curl -s -f --retry 3 --retry-delay 2 "$url" | \
        grep -o 'href="[^"]*\.vdi"' | \
        sed 's/href="//;s/"$//' | \
        sed 's:.*/::' | \
        grep -E '^chr-[0-9]+\.[0-9]+\.[0-9]+\.vdi$' | \
        sort -V -t. -k1,1n -k2,2n -k3,3n
}

# Function to get version from RSS
get_latest_from_rss() {
    local rss_url="https://cdn.mikrotik.com/routeros/latest-stable.rss"
    
    echo "Fetching RSS feed from: $rss_url"
    
    # Download RSS feed dengan debugging
    local rss_content
    rss_content=$(curl -s -f \
        --retry 3 \
        --retry-delay 2 \
        --max-time 10 \
        "$rss_url" 2>/dev/null)
    
    local curl_exit=$?
    echo "Curl exit code: $curl_exit"
    echo "RSS content length: ${#rss_content} characters"
    
    if [[ $curl_exit -ne 0 ]]; then
        echo "❌ Failed to download RSS feed"
        return 1
    fi
    
    # Debug: show first few lines
    echo "First 200 chars of RSS:"
    echo "${rss_content:0:200}"
    echo "..."
    
    # Extract version from <title> tag
    local version
    version=$(echo "$rss_content" | \
        grep -o '<title>RouterOS [0-9.]* \[stable\]</title>' | \
        head -1 | \
        sed 's/<title>RouterOS //;s/ \[stable\]<\/title>//')
    
    echo "Extracted version from title: '$version'"
    
    if [[ -n "$version" ]] && [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "✅ Valid version from title: $version"
        echo "$version"
        return 0
    fi
    
    # Alternative: Extract from <link> tag
    version=$(echo "$rss_content" | \
        grep -o '<link>https://mikrotik.com/download\?v=[0-9.]*</link>' | \
        head -1 | \
        sed 's|<link>https://mikrotik.com/download?v=||;s|</link>||')
    
    echo "Extracted version from link: '$version'"
    
    if [[ -n "$version" ]] && [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "✅ Valid version from link: $version"
        echo "$version"
        return 0
    fi
    
    # Try alternative pattern for link
    version=$(echo "$rss_content" | \
        grep -o 'download?v=[0-9.]*' | \
        head -1 | \
        sed 's/download?v=//')
    
    echo "Extracted version from download link: '$version'"
    
    if [[ -n "$version" ]] && [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "✅ Valid version from download link: $version"
        echo "$version"
        return 0
    fi
    
    echo "❌ Could not extract version from RSS"
    return 1
}

# Main execution
echo "=== DEBUG MODE ==="
echo "Current directory: $(pwd)"
echo "Files in directory:"
ls -la

# Try to get version from RSS
echo ""
echo "Trying RSS feed method..."
VERSION=""

if VERSION_RSS=$(get_latest_from_rss); then
    echo "✅ RSS feed parsing successful"
    VERSION="$VERSION_RSS"
    echo "Parsed version: $VERSION"
else
    echo "❌ RSS feed parsing failed"
    exit 0  # Exit gracefully
fi

echo ""
echo "=== VERSION VALIDATION ==="
echo "Version to check: '$VERSION'"
echo "Version length: ${#VERSION}"

if [[ -z "$VERSION" ]]; then
    echo "❌ Version is empty"
    exit 0
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ Invalid version format: $VERSION"
    echo "Expected format: X.Y.Z"
    exit 0
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
echo "Current version in Dockerfile: '$CURRENT'"

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
sed -i "s/ARG ROUTEROS_VERSION=\".*\"/ARG ROUTEROS_VERSION=\"$VERSION\"/" Dockerfile

# Verify the update
NEW_VERSION=$(grep 'ARG ROUTEROS_VERSION=' Dockerfile | cut -d'"' -f2)
if [[ "$NEW_VERSION" != "$VERSION" ]]; then
    echo "❌ Failed to update Dockerfile"
    echo "Expected: $VERSION, Got: $NEW_VERSION"
    exit 1
fi

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
if git diff --cached --quiet; then
    echo "⚠️ No changes to commit"
    exit 0
fi

git commit -m "chore: update RouterOS to $VERSION" \
           -m "Automated update from $CURRENT to $VERSION"
echo "✓ Changes committed"

# Push changes
echo "Pushing to main branch..."
git push origin main
echo "✓ Main branch updated"

# Create and push tag
echo "Creating tag v$VERSION..."
if git tag -l | grep -q "v$VERSION"; then
    echo "⚠️ Tag v$VERSION already exists"
else
    git tag -a "v$VERSION" -m "RouterOS $VERSION"
    git push origin "v$VERSION"
    echo "✓ Tag v$VERSION created and pushed"
fi

# Cleanup
rm -f Dockerfile.bak

echo "✅ Update completed successfully!"
echo "📦 New version: $VERSION"