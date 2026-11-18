#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo "==> Preparing clean GitHub synchronization..."

if ! command -v gh >/dev/null 2>&1; then
    echo "❌ Error: GitHub CLI ('gh') is required." >&2
    exit 1
fi

TOKEN=$(gh auth token 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
    echo "❌ Error: Could not obtain GitHub token from 'gh'." >&2
    exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Fetch latest upstream
if git remote get-url upstream >/dev/null 2>&1; then
    git fetch upstream main --quiet
fi

# Switch to clean github-release branch
git checkout github-release

# Synchronize working tree from main without pulling old history
git checkout main -- .
# Ensure upstream workflows are preserved so Actions stay compatible
if git remote get-url upstream >/dev/null 2>&1; then
    git checkout upstream/main -- .github/workflows 2>/dev/null || true
fi

git add -A

if git diff --cached --quiet; then
    echo "ℹ️  No changes to commit for GitHub (already in sync)."
else
    GIT_COMMITTER_NAME="rennan101us" \
    GIT_COMMITTER_EMAIL="358336950+rennan101us@users.noreply.github.com" \
    git commit -m "sync: update to latest release" \
        --author="rennan101us <358336950+rennan101us@users.noreply.github.com>"
fi

# Push to GitHub main
echo "==> Pushing clean updates to GitHub..."
git push "https://x-access-token:${TOKEN}@github.com/rennan101us/nxnative_Launcher.git" github-release:main

# Return to original branch
git checkout "$CURRENT_BRANCH"

echo "✅ GitHub repository successfully synced!"
