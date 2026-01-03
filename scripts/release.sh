#!/usr/bin/env bash
set -e

RELEASE_NAME="Released on $(date +%Y%m%d%H%M)"

# Configure git (should be done in workflow, but ensure it's set)
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Checkout or create release branch
if git show-ref --verify --quiet refs/heads/release; then
  git checkout release
else
  git checkout --orphan release
fi

# Remove all files except .git and publish to ensure clean state
find . -mindepth 1 -maxdepth 1 ! -name '.git' ! -name 'publish' -exec rm -rf {} + 2>/dev/null || true

# Copy published files
mv ./publish/* .
rm -rf ./publish

# Remove .github directory if it exists (shouldn't be in publish, but be safe)
rm -rf .github 2>/dev/null || true

# Add all files except .github
git add -A
# git reset HEAD .github 2>/dev/null || true

# Add and commit
if git diff --staged --quiet; then
  echo "No changes to commit"
  exit 0
fi

git commit -m "$RELEASE_NAME"

git push -f origin release
