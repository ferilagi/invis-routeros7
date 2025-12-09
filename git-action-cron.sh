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

# Function to get version from RSS Stable
get_latest_from_rss() {
    local rss_url="https://cdn.mikrotik.com/routeros/latest-stable.rss"
    
    echo "Fetching RSS feed from: $rss_url"
    
    # Download RSS feed
    local rss_content
    rss_content=$(curl -s -f \
        --retry 3 \
        --retry-delay 2 \
        --max-time 10 \
        "$rss_url" 2>/dev/null) || return 1
    
    # Extract version from <title> tag
    local version
    version=$(echo "$rss_content" | \
        grep -o '<title>RouterOS [0-9.]* \[stable\]</title>' | \
        head -1 | \
        sed 's/<title>RouterOS //;s/ \[stable\]<\/title>//')
    
    if [[ -n "$version" ]] && [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$version"
        return 0
    fi
    
    # Alternative: Extract from <link> tag
    version=$(echo "$rss_content" | \
        grep -o '<link>https://mikrotik.com/download?v=[0-9.]*</link>' | \
        head -1 | \
        sed 's|<link>https://mikrotik.com/download?v=||;s|</link>||')
    
    if [[ -n "$version" ]] && [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$version"
        return 0
    fi
    
    return 1
}

# Function to get VDI filename from version
get_vdi_filename() {
    local version="$1"
    echo "chr-${version}.vdi"
}

# Get versions from both pages dengan error handling
echo "Fetching RouterOS versions..."
VERSIONS=""

if VERSION_RSS=$(get_latest_from_rss); then
    echo "✅ RSS feed successful"
    VERSION="$VERSION_RSS"
else
    echo "❌ RSS feed failed, trying fallback HTML method..."
    
    # Fallback to HTML scraping (with improved parsing)
    FALLBACK_URL="https://mikrotik.com/download"
    
    # Try multiple patterns
    for pattern in 'chr-[0-9]*\.[0-9]*\.[0-9]*\.vdi' 'routeros/[0-9]*\.[0-9]*\.[0-9]*/' 'v=[0-9]*\.[0-9]*\.[0-9]*'; do
        echo "Trying pattern: $pattern"
        
        if VERSION_HTML=$(curl -s -f --max-time 10 "$FALLBACK_URL" | \
            grep -o -E "$pattern" | \
            grep -E '[0-9]+\.[0-9]+\.[0-9]+' | \
            sed 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/' | \
            sort -Vu | tail -1); then
            
            if [[ -n "$VERSION_HTML" ]] && [[ "$VERSION_HTML" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                VERSION="$VERSION_HTML"
                echo "✅ HTML fallback successful"
                break
            fi
        fi
    done
fi

if [[ -z "$VERSIONS" ]]; then
    echo "❌ Failed to fetch any versions"
    exit 1
fi

# Get unique sorted versions
ALL_VERSIONS=$(echo "$VERSIONS" | sort -Vu)

echo "Found $(echo "$ALL_VERSIONS" | wc -l) versions total"
echo "Latest 5 versions:"
echo "$ALL_VERSIONS" | tail -5

# Get latest version
LATEST=$(echo "$ALL_VERSIONS" | tail -1)
[[ -z "$LATEST" ]] && { echo "No versions found"; exit 1; }

VERSION=$(echo "$LATEST" | sed 's/chr-//;s/\.vdi//')
echo "Latest version: $VERSION"

# Check current version in Dockerfile
if [[ ! -f "Dockerfile" ]]; then
    echo "❌ Dockerfile not found!"
    exit 1
fi

CURRENT=$(grep 'ARG ROUTEROS_VERSION=' Dockerfile | cut -d'"' -f2)
if [[ -z "$CURRENT" ]]; then
    echo "❌ Could not find ROUTEROS_VERSION in Dockerfile"
    exit 1
fi

echo "Current version in Dockerfile: $CURRENT"

if [[ "$VERSION" == "$CURRENT" ]]; then
    echo "✅ Already at latest version ($VERSION)"
    exit 0
fi

# Validate version format (X.Y.Z)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ Invalid version format: $VERSION"
    exit 1
fi

echo "🔄 Updating from $CURRENT to $VERSION"

# Backup Dockerfile
cp Dockerfile Dockerfile.bak

# Update Dockerfile
if sed -i "s/ARG ROUTEROS_VERSION=\".*\"/ARG ROUTEROS_VERSION=\"$VERSION\"/" Dockerfile; then
    echo "✓ Dockerfile updated"
else
    echo "❌ Failed to update Dockerfile"
    cp Dockerfile.bak Dockerfile
    exit 1
fi

# Verify the update
NEW_VERSION=$(grep 'ARG ROUTEROS_VERSION=' Dockerfile | cut -d'"' -f2)
if [[ "$NEW_VERSION" != "$VERSION" ]]; then
    echo "❌ Update verification failed"
    echo "Expected: $VERSION, Got: $NEW_VERSION"
    cp Dockerfile.bak Dockerfile
    exit 1
fi

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