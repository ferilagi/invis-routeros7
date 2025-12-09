#!/usr/bin/env bash

# Cron fix
cd "$(dirname "$0")"

# Enable strict mode
set -euo pipefail

function getTarballs {
    curl -s -f https://mikrotik.com/download/archive | \
        grep -o '<a href=['"'"'"][^"'"'"']*['"'"'"]' | \
        sed -e 's/^<a href=["'"'"']//' -e 's/["'"'"']$//' | \
        grep -i vdi | \
        sed 's:.*/::' | \
        sort -V

    curl -s -f https://mikrotik.com/download | \
        grep -o '<a href=['"'"'"][^"'"'"']*['"'"'"]' | \
        sed -e 's/^<a href=["'"'"']//' -e 's/["'"'"']$//' | \
        grep -i vdi | \
        sed 's:.*/::' | \
        sort -V
}

function getTag {
    echo "$1" | sed -r 's/chr\-(.*)\.vdi/\1/gi'
}

function checkTag {
    git rev-list "$1" 2>/dev/null || true
}

# Setup git remote
git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

# Fetch all tags
git fetch --tags

HAS_UPDATE=false
LATEST_TAG=""

getTarballs | while read -r line; do
    tag=$(getTag "$line")
    echo ">>> Checking: $line -> $tag"

    if [ -z "$(checkTag "$tag")" ]; then
        url="https://download.mikrotik.com/routeros/$tag/chr-$tag.vdi"
        echo ">>> Testing URL: $url"
        
        if curl -s -f --head "$url" > /dev/null 2>&1; then
            echo ">>> ✓ URL exists: $url"
            
            # Update Dockerfile
            if [ -f Dockerfile ]; then
                sed -r "s/(ROUTEROS_VERSON=\")(.*)(\")/\1$tag\3/g" -i Dockerfile
                git add Dockerfile
                git commit -m "Release of RouterOS changed to $tag"
                git push origin main
                git tag "$tag"
                git push origin "$tag"
                
                HAS_UPDATE=true
                LATEST_TAG="$tag"
                echo "::set-output name=has_update::true"
                echo "::set-output name=new_tag::$tag"
            else
                echo ">>> ✗ Dockerfile not found"
            fi
        else
            echo ">>> ✗ URL doesn't exist: $url"
        fi
    else
        echo ">>> ✓ Tag $tag already exists"
    fi
done

if [ "$HAS_UPDATE" = true ]; then
    echo "========================================="
    echo "New version detected: $LATEST_TAG"
    echo "========================================="
    exit 0
else
    echo "========================================="
    echo "No new version found"
    echo "========================================="
    exit 1
fi